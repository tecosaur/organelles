#!/usr/bin/env bash
# Create the service key material under `secrets/keys/`.
#
# These sign and encrypt data that already exists, so replacing one is
# destructive: a fresh `authelia-storage` leaves the encrypted Postgres columns
# unreadable. Only missing keys are generated; rotation is a deliberate delete
# and re-run.

set -euo pipefail

secrets_dir="$(dirname "$(dirname "$(realpath "$0")")")"
keys_dir="$secrets_dir/keys"
rules="$secrets_dir/secrets.nix"
tool_name="init-keys"
# shellcheck source=lib.sh
. "$secrets_dir/scripts/lib.sh"

# name:kind. Every node holds this material: instances must share it to accept
# each other's tokens. A garage-node key is one node's identity, held by it alone.
# A meilisearch key derives from meilisearch-master, so follows it.
readonly service_keys=(
    "authelia-jwt:rand"
    "authelia-oidc-hmac:rand"
    "authelia-oidc-issuer.pem:rsa"
    "authelia-session:rand"
    "authelia-storage:rand"
    "bulwark-session:rand"
    "dkim-tecosaur.net:dkim"
    "garage-mail-overflow:s3-key"
    "garage-mail-primary:s3-key"
    "garage-node-centrosome:garage-node"
    "garage-node-golgi:garage-node"
    "garage-overflow-rpc:hex"
    "gatus-push:rand"
    "lldap-jwt:rand"
    "lldap-key-seed:rand"
    "meilisearch-master:rand"
    "meilisearch-jellyfin:meilisearch"
    "meilisearch-stalwart:meilisearch"
    "multi-scrobbler-jellyfin:rand"
    "multi-scrobbler-koito:rand"
    "patroni-restapi:rand"
    "postgresql-ha-replication:rand"
    "s3-overflow-client:s3-key"
    "status-alert-topic:rand"
    "valkey-ha:rand"
    "valkey-s3-overflow:rand"
    "valkey-stalwart:rand"
    "vaultwarden-rsa.pem:rsa"
)

function usage() {
    printf '\e[1mUsage:\e[0m init-keys.sh [\e[36m--list\e[0m]

Generate any key in secrets/keys/ that does not yet exist, and register it in
secrets.nix. Existing keys are left untouched and reported as present.

  \e[36m--list\e[0m   show each key and whether it exists, without generating anything
  \e[36m--help\e[0m   show this help

To rotate a key, delete it and re-run. Read the warning in the header first:
for most of these, rotation makes existing data unreadable.\n'
}

function generate_rand() {
    nix_run 'nixpkgs#authelia' -- crypto rand --length 64 --charset alphanumeric |
        sed -n 's/^Random Value: //p'
}

function generate_rsa() {
    local dir
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    # Authelia derives the public half, so only private.pem is kept.
    nix_run 'nixpkgs#authelia' -- crypto pair rsa generate --directory "$dir" >/dev/null ||
        die "authelia failed to generate an RSA keypair"
    [ -s "$dir/private.pem" ] || die "authelia wrote no private.pem"
    cat "$dir/private.pem"
}

# Garage's node_key is libsodium's ed25519 secret key, seed then public key,
# kept base64-encoded; the public half, hex as `garage node id` shows it, is
# committed beside it for garage.nix to read at evaluation time.
function generate_garage_node() {
    local name="$1" der public
    der="$(nix_run 'nixpkgs#openssl' -- genpkey -algorithm ed25519 -outform DER | base64 -w0)" ||
        die "openssl failed to generate an ed25519 key for $name"
    public="$(base64 -d <<<"$der" |
        nix_run 'nixpkgs#openssl' -- pkey -inform DER -pubout -outform DER | tail -c 32 | base64 -w0)" ||
        die "openssl failed to derive the public key for $name"
    { base64 -d <<<"$public" | od -An -tx1 -v | tr -d ' \n'; echo; } >"$keys_dir/$name.pub" ||
        die "could not write $keys_dir/$name.pub"
    { base64 -d <<<"$der" | tail -c 32; base64 -d <<<"$public"; } | base64 -w0
}

# RSA rather than Ed25519, which not every receiver verifies. The TXT record
# for <selector>._domainkey is committed beside it for the DNS statics.
function generate_dkim() {
    local name="$1" pem public
    pem="$(nix_run 'nixpkgs#openssl' -- genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048)" ||
        die "openssl failed to generate an RSA key for $name"
    public="$(nix_run 'nixpkgs#openssl' -- pkey -pubout -outform DER <<<"$pem" | base64 -w0)" ||
        die "openssl failed to derive the public key for $name"
    printf 'v=DKIM1; k=rsa; p=%s\n' "$public" >"$keys_dir/$name.txt" ||
        die "could not write $keys_dir/$name.txt"
    printf '%s\n' "$pem"
}

# An S3 secret key, with its ID committed beside it for the modules to read at
# evaluation time. Garage takes IDs of GK and 24 hex digits.
function generate_s3_key() {
    local name="$1" id
    id="GK$(nix_run 'nixpkgs#openssl' -- rand -hex 12)" || die "openssl failed to draw an ID for $name"
    echo "$id" >"$keys_dir/$name.id" || die "could not write $keys_dir/$name.id"
    nix_run 'nixpkgs#openssl' -- rand -hex 32 | tr -d '\n'
}

# Meilisearch makes a key the HMAC of its uid under the master key, so a scoped
# key is derived here and only declared on the server; the uid is committed
# beside it for meilisearch.nix to read at evaluation time.
function generate_meilisearch() {
    local name="$1" master uid
    master="$(cd "$secrets_dir" && nix_run github:ryantm/agenix -- -d keys/meilisearch-master.age)" ||
        die "agenix failed to decrypt keys/meilisearch-master.age, from which $name derives;" \
            "create it first"
    uid="$(cat /proc/sys/kernel/random/uuid)"
    echo "$uid" >"$keys_dir/$name.uid" || die "could not write $keys_dir/$name.uid"
    printf '%s' "$uid" | nix_run 'nixpkgs#openssl' -- dgst -sha256 -hmac "$master" -r | cut -d' ' -f1 | tr -d '\n'
}

function generate() {
    local kind="$1" name="$2" value
    case "$kind" in
        rand)
            value="$(generate_rand)"
            [ -n "$value" ] || die "could not parse authelia's random value"
            printf '%s' "$value" ;;
        hex) nix_run 'nixpkgs#openssl' -- rand -hex 32 | tr -d '\n' ;;
        garage-node) generate_garage_node "$name" ;;
        dkim) generate_dkim "$name" ;;
        meilisearch) generate_meilisearch "$name" ;;
        s3-key) generate_s3_key "$name" ;;
        rsa) generate_rsa ;;
        *) die "unknown key kind '$kind'" ;;
    esac
}

function list_keys() {
    local spec name
    for spec in "${service_keys[@]}"; do
        IFS=: read -r name _ <<<"$spec"
        if [ -e "$keys_dir/$name.age" ]; then
            printf '  %s %s\n' "$mark_present" "$name.age"
        else
            printf '  %s %s\n' "$mark_absent" "$name.age"
        fi
    done
}

function init_key() {
    local name="$1" kind="$2" group="$3"
    local age_file="keys/$name.age"
    if [ -e "$keys_dir/$name.age" ]; then
        return 1
    fi
    echo "$name:"
    # agenix reads secrets.nix for the recipients, so the entry must exist first.
    register_secret "$age_file" "$group"
    # A non-interactive stdin makes agenix use `cp /dev/stdin` as its editor.
    generate "$kind" "$name" |
        (cd "$secrets_dir" && nix_run github:ryantm/agenix -- -e "$age_file") ||
        die "agenix failed to encrypt $age_file;" \
            "secrets.nix now names $age_file, which does not exist yet"
    printf '  %s %s\n' "$mark_wrote" "$age_file"
    return 0
}

case "${1-}" in
    --help) usage; exit 0 ;;
    --list) list_keys; exit 0 ;;
    "") ;;
    *) die "unknown option '$1'" ;;
esac

[ -f "$rules" ] || die "no secrets.nix at $rules"
read_rules
mkdir -p "$keys_dir"

created=0
# Word-split deliberately: node_names emits one name per line.
# shellcheck disable=SC2046
group="$(recipients_to_group "$(local_binding)" $(node_names))"
for spec in "${service_keys[@]}"; do
    IFS=: read -r name kind <<<"$spec"
    if [ "$kind" = garage-node ]; then
        key_group="$(recipients_to_group "$(local_binding)" "${name#garage-node-}")"
    else
        key_group="$group"
    fi
    init_key "$name" "$kind" "$key_group" && created=$((created + 1)) || true
done

[ "$created" -gt 0 ] || exit 2
printf '\n%s %d key%s generated\n' "$mark_present" \
       "$created" "$([ "$created" -eq 1 ] || echo s)"
