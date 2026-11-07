#!/usr/bin/env bash
# Generate paired OIDC credentials for Authelia clients.
#
# Each client's secret and its digest must share a name, or sign-in fails at token
# exchange rather than at evaluation.

set -euo pipefail

secrets_dir="$(dirname "$(dirname "$(realpath "$0")")")"
rules="$secrets_dir/secrets.nix"
tool_name="make-oidc"
# shellcheck source=lib.sh
. "$secrets_dir/scripts/lib.sh"

function usage() {
    printf '\e[1mUsage:\e[0m make-oidc.sh [\e[36m--refresh\e[0m] (\e[36mNAME\e[0m... | \e[36m--all\e[0m)

  \e[36mNAME\e[0m          a client ID declared in the site.nix of its app (auth.clients),
                e.g. \e[36mheadplane\e[0m
  \e[36m--all\e[0m         refresh every client that already has an oidc/*-hash.txt
  \e[36m-r, --refresh\e[0m regenerate existing credentials without asking
  \e[36m--help\e[0m        show this help

Overwriting existing credentials is confirmed first, unless \e[36m--refresh\e[0m is given.\n'
}

# Ask a yes/no question, defaulting to no. With no terminal there is nobody to
# ask, and overwriting a secret is not a safe default.
function confirm() {
    local reply
    [ -t 0 ] && [ -e /dev/tty ] || return 1
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r reply </dev/tty || { printf '\n' >/dev/tty; return 1; }
    [[ "$reply" == [yY]* ]]
}

# ---------------------------------------------------------------- credentials

# Emit the secret and its digest as two NUL-terminated fields. Authelia is
# invoked once per app: it generates the pair together.
function generate_credentials() {
    local output secret digest
    output="$(nix_run 'nixpkgs#authelia' -- crypto hash generate pbkdf2 \
                  --random --random.length 72 --random.charset rfc3986)" ||
        die "authelia failed to generate credentials"
    secret="$(sed -n 's/^Random Password: //p' <<<"$output")"
    digest="$(sed -n 's/^Digest: //p' <<<"$output")"
    [ -n "$secret" ] && [ -n "$digest" ] ||
        die "could not parse authelia output:"$'\n'"$output"
    printf '%s\0%s\0' "$secret" "$digest"
}

function make_oidc() {
    local name="$1"
    local age_file="oidc/$name-secret.age" txt_file="oidc/$name-hash.txt"
    echo "$name:"
    register_secret "$age_file"
    local secret digest
    { IFS= read -r -d '' secret; IFS= read -r -d '' digest; } < <(generate_credentials)
    # The digest follows its secret, so a failed encryption leaves the old pair matched
    printf '%s' "$secret" |
        (cd "$secrets_dir" && nix_run github:ryantm/agenix -- -e "$age_file") ||
        die "agenix failed to encrypt $age_file; $txt_file is unchanged"
    printf '  %s %s\n' "$mark_wrote" "$age_file"
    printf '%s\n' "$digest" > "$secrets_dir/$txt_file" ||
        die "could not write $secrets_dir/$txt_file, so it no longer matches $age_file; re-run for $name"
    printf '  %s %s\n' "$mark_wrote" "$txt_file"
}

# ----------------------------------------------------------------------- main

function parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --help) usage; exit 0 ;;
            -r|--refresh) refresh=true; shift ;;
            --all) all=true; refresh=true; shift ;;
            -*) die "unknown option '$1'" ;;
            *) names+=("$1"); shift ;;
        esac
    done
}

function confirm_overwrites() {
    local name existing=()
    for name in "$@"; do
        [ -e "$secrets_dir/oidc/$name-secret.age" ] && existing+=("$name")
    done
    [ ${#existing[@]} -gt 0 ] || return 0
    confirm "credentials already exist for ${existing[*]}; regenerate?" ||
        die "left unchanged"
}

# Apps with a digest but no encrypted secret cannot be refreshed as a pair, so
# they are reported rather than silently passed over: some keep the secret
# elsewhere (forgejo in its database, mealie in a bundled env file), but an
# unpaired digest is just as likely to be an oversight.
function all_refreshable() {
    local txt name unpaired=()
    for txt in "$secrets_dir"/oidc/*-hash.txt; do
        [ -e "$txt" ] || die "no existing credentials to refresh"
        name="$(basename "$txt" -hash.txt)"
        if [ -e "$secrets_dir/oidc/$name-secret.age" ]; then
            printf '%s\n' "$name"
        else
            unpaired+=("$name")
        fi
    done
    [ ${#unpaired[@]} -eq 0 ] ||
        echo "make-oidc: skipping ${unpaired[*]}: digest with no encrypted secret" >&2
}

[ -f "$rules" ] || die "no secrets.nix at $rules"
read_recipients

refresh=false
all=false
names=()
parse_args "$@"

[ "$refresh" = true ] || confirm_overwrites "${names[@]}"

binding="$(local_binding)"
[ -n "$binding" ] ||
    echo "make-oidc: warning: no ~/.ssh/id_*.pub is a recipient in" \
         "recipients.nix; you will not be able to decrypt these secrets" >&2

if [ "$all" = true ]; then
    [ ${#names[@]} -eq 0 ] || die "--all takes no app names"
    mapfile -t names < <(all_refreshable)
fi
[ ${#names[@]} -gt 0 ] || { usage; exit 2; }

for name in "${names[@]}"; do
    make_oidc "$name"
done

printf '\n%s %d credential%s generated: %s\n' "$mark_present" \
       "${#names[@]}" "$([ ${#names[@]} -eq 1 ] || echo s)" "${names[*]}"
