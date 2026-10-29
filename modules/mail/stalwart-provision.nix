{ lib, pkgs }:

# Applies Stalwart's settings (its first argument) through a recovery-mode Stalwart, retracting
# those since dropped, gives exactly the admins' accounts the Admin role and installs Sieve stubs;
# only the scheduler initialises a new store.

{
  package,
  cli,
  # addressing.nix's model
  addressing,
  # The global Sieve script each listed account's stub includes
  filing-script,
  http-port,
  recovery-port,
}:
let
  local-url = "http://127.0.0.1:${toString http-port}";
  recovery-url = "http://127.0.0.1:${toString recovery-port}";
  stub-script = ''
    require "include";
    include :global "${filing-script}";
  '';
  # Every listed account's active script, including the global filing script,
  # named for its content so a current stub is recognised without its blob
  stub-name = "${filing-script}-${builtins.substring 0 12 (builtins.hashString "sha256" stub-script)}";
  stub = pkgs.writeText "sieve-stub" stub-script;
  retract = pkgs.writeShellApplication {
    name = "stalwart-retract";
    runtimeInputs = with pkgs; [ coreutils curl jq cli ];
    text = builtins.readFile ./stalwart-retract.sh;
  };
in
pkgs.writeShellApplication {
  name = "stalwart-provision";
  runtimeInputs = with pkgs; [ coreutils curl jq cli systemd ];
  text = ''
    all_settings="$1"
    # ACME goes apart and last: creating the provider reaches Let's Encrypt, and Stalwart never orders for
    # a domain created with automatic certificates but no records to publish
    acme='.object == "AcmeProvider" or .object == "DnsServer"
      or (.object == "Domain" and any(.value[]; .certificateManagement."@type"? == "Automatic"))'
    settings="$RUNTIME_DIRECTORY/settings.ndjson" acme_ops="$RUNTIME_DIRECTORY/acme.ndjson"
    jq -c "select(($acme) | not)" "$all_settings" >"$settings"
    jq -c "select($acme)" "$all_settings" >"$acme_ops"
    export XDG_CACHE_HOME="$CACHE_DIRECTORY"
    password=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    server=
    trap 'stop_server' EXIT
    start_server() {
      local mode="$1" url="$2" tries=0
      (
        if [ "$mode" = recovery ]; then
          # Recovery mode binds [::]:<port>, unconfigurably; no firewall opens it
          export STALWART_RECOVERY_MODE=1 STALWART_RECOVERY_MODE_PORT=${toString recovery-port}
          export STALWART_RECOVERY_ADMIN="provision:$password"
        fi
        unset NOTIFY_SOCKET
        exec ${lib.getExe package} --config "$RUNTIME_DIRECTORY/config.json"
      ) &
      server=$!
      until curl -sf -o /dev/null "$url/healthz/live"; do
        kill -0 "$server" 2>/dev/null || { echo "stalwart: the $mode server exited before answering" >&2; exit 1; }
        [ $((tries += 1)) -le 240 ] || { echo "stalwart: the $mode server did not answer within two minutes" >&2; exit 1; }
        sleep 0.5
      done
    }
    stop_server() {
      [ -n "$server" ] || return 0
      kill -INT "$server" 2>/dev/null || true
      wait "$server" || true
      server=
    }
    as_provision() { STALWART_URL=${recovery-url} STALWART_USER=provision STALWART_PASSWORD="$password" "$@"; }
    apply() { as_provision stalwart-cli apply --quiet --file "$1"; }
    # Requests carry the password in a header read from a pipe, never in argv
    basic() { printf 'Authorization: Basic %s' "$(printf '%s:%s' "$1" "$password" | base64 -w0)"; }
    jmap() {
      curl -sS --fail-with-body -H @<(basic "$1") -H 'Content-Type: application/json' \
        --data-binary @- ${recovery-url}/jmap/
    }
    using='["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve", "urn:stalwart:jmap"]'
    check() {
      jq -e '[.methodResponses[] | select(.[0] == "error"
               or (.[1] | (.notCreated // {}) + (.notUpdated // {}) + (.notDestroyed // {}) != {}))] == []' \
        >/dev/null <<<"$1" || { echo "stalwart: $2 failed: $1" >&2; return 1; }
    }
    # Stalwart creates its default roles only at a normal start while Authentication
    # is unset, so on a new store the settings, which set it, wait for one
    # True once the store has them; a failed listing is a fault, not an empty store
    has_roles() {
      local roles
      roles=$(jq -n --argjson using "$using" '{using: $using, methodCalls: [["x:Role/query", {}, "0"]]}' | jmap provision) || true
      check "$roles" "listing roles" || exit 1
      jq -e '.methodResponses[0][1].ids != []' >/dev/null <<<"$roles"
    }
    init_store() {
      has_roles && return 0
      if [ "''${STALWART_ROLE:-}" != scheduler ]; then
        echo "stalwart: a new store; waiting for the scheduler host to initialise it"
        systemd-notify --status="Waiting for the scheduler host to initialise the new store" || true
        until has_roles; do sleep 5; done
        return 0
      fi
      echo "stalwart: a new store; starting once normally for Stalwart's defaults"
      apply <(jq -c 'select(.object != "Authentication")' "$settings")
      stop_server
      start_server normal ${local-url}
      stop_server
      start_server recovery ${recovery-url}
    }
    # True when a request failed only for want of a store, as while the primary is down
    unavailable() {
      jq -e '[.methodResponses[] | if .[0] == "error" then .[1].type
               else .[1] | (.notCreated // {}) + (.notUpdated // {}) + (.notDestroyed // {}) | .[].type end]
             | length > 0 and all(. == "serverUnavailable")' >/dev/null <<<"$1"
    }
    # Returns 2 where only a store was unavailable (the next start retries), 1 on other failures
    store_set() {
      local user="$1" request="$2" what="$3" response
      response=$(jmap "$user" <<<"$request") || { echo "stalwart: $what failed: $response" >&2; return 1; }
      check "$response" "$what" && return 0
      unavailable "$response" || return 1
      echo "stalwart: $what waits for the store; the next start retries" >&2
      return 2
    }
    # A current stub is left alone: replacing one reads the old blob, unreadable while the primary
    # is down. A new stub is activated only where a stub or nothing was, so a vacation keeps its place.
    install_sieve_stub() {
      local account="$1" name="$2" script="$3" user="$1%provision" session id upload status blob scripts request stale
      local stub='^${filing-script}(-[0-9a-f]{12})?$'
      session=$(curl -sS --fail-with-body -H @<(basic "$user") ${recovery-url}/jmap/session)
      id=$(jq -er '.primaryAccounts["urn:ietf:params:jmap:sieve"]' <<<"$session")
      scripts=$(jq -n --arg id "$id" --argjson using "$using" \
        '{using: $using, methodCalls: [["SieveScript/get", {accountId: $id, ids: null, properties: ["name", "isActive"]}, "0"]]}' |
        jmap "$user")
      check "$scripts" "listing $account's Sieve scripts"
      if ! jq -e --arg name "$name" '.methodResponses[0][1].list | any(.name == $name)' >/dev/null <<<"$scripts"; then
        upload=$(curl -sS -w '\n%{http_code}' -H @<(basic "$user") -H 'Content-Type: application/sieve' \
          --data-binary @"$script" "${recovery-url}/jmap/upload/$id/")
        status=''${upload##*$'\n'}
        case "$status" in
          2??) blob=$(jq -er .blobId <<<"''${upload%$'\n'*}") ;;
          5??) echo "stalwart: uploading $account's Sieve stub $name waits for the store (HTTP $status); the next start retries" >&2
               return 0 ;;
          *) echo "stalwart: uploading $account's Sieve stub $name failed: HTTP $status ''${upload%$'\n'*}" >&2
             return 1 ;;
        esac
        request=$(jq --arg id "$id" --arg name "$name" --arg blob "$blob" --arg stub "$stub" --argjson using "$using" '
          .methodResponses[0][1].list as $scripts
          | {accountId: $id, create: {stub: {name: $name, blobId: $blob}}}
            + (if any($scripts[]; .isActive and (.name | test($stub))) or (any($scripts[]; .isActive) | not)
               then {onSuccessActivateScript: "#stub"} else {} end)
          | {using: $using, methodCalls: [["SieveScript/set", ., "0"]]}' <<<"$scripts")
        store_set "$user" "$request" "installing $account's Sieve stub $name" || { [ $? -eq 2 ] && return 0; return 1; }
      fi
      stale=$(jq -c --arg name "$name" --arg stub "$stub" \
        '[.methodResponses[0][1].list[] | select((.name | test($stub)) and .name != $name) | .id]' <<<"$scripts")
      [ "$stale" = "[]" ] && return 0
      request=$(jq -n --arg id "$id" --argjson stale "$stale" --argjson using "$using" \
        '{using: $using, methodCalls: [["SieveScript/set", {accountId: $id, destroy: $stale}, "0"]]}')
      store_set "$user" "$request" "removing $account's old Sieve stubs" || { [ $? -eq 2 ] && return 0; return 1; }
    }
    # Accounts created at sign-in are not in the settings, so their role waits for a start after it
    reconcile_admins() {
      local response request
      response=$(jq -n --argjson using "$using" '{using: $using, methodCalls: [
        ["x:Account/query", {}, "0"],
        ["x:Account/get", {"#ids": {resultOf: "0", name: "x:Account/query", path: "/ids"}, properties: ["name", "domainId", "roles"]}, "1"],
        ["x:Domain/get", {ids: null, properties: ["name"]}, "2"]]}' | jmap provision)
      if ! check "$response" "listing accounts"; then
        unavailable "$response" || return 1
        echo "stalwart: setting admins' roles waits for the store; the next start retries" >&2
        return 0
      fi
      request=$(jq --argjson admins '${builtins.toJSON addressing.admin-accounts}' --argjson using "$using" '
        (.methodResponses[2][1].list | map({(.id): .name}) | add) as $domains
        | [.methodResponses[1][1].list[]
           | ((.name + "@" + $domains[.domainId]) | IN($admins[])) as $admin
           | select($admin != (.roles."@type" == "Admin"))
           | {(.id): {roles: {"@type": (if $admin then "Admin" else "User" end)}}}]
        | if . == [] then empty
          else {using: $using, methodCalls: [["x:Account/set", {update: add}, "0"]]} end' <<<"$response")
      [ -z "$request" ] || store_set provision "$request" "setting admins' roles" || { [ $? -eq 2 ] && return 0; return 1; }
    }
    start_server recovery ${recovery-url}
    init_store
    # Shared settings: a host still on an older generation re-applies its own, so deploy both together
    apply "$settings"
    # Mail never waits on Let's Encrypt: unreachable, it leaves the certificate as it is until the next start
    if [ -s "$acme_ops" ] && ! output=$(apply "$acme_ops" 2>&1); then
      [[ $output =~ "Failed to create ACME account: "(HTTP|JSON)" error" ]] || { echo "$output" >&2; exit 1; }
      echo "stalwart: Let's Encrypt is unreachable, so the certificate waits for the next start: $output" >&2
    fi
    reconcile_admins
    # Retracted are the settings dropped since those this host last applied, else its second argument's,
    # from before it kept a record
    record="$STATE_DIRECTORY/applied-settings.ndjson" previous=
    if [ -s "$record" ]; then previous="$record"; elif [ -s "''${2:-}" ]; then previous="$2"; fi
    if [ -n "$previous" ] && ! as_provision ${lib.getExe retract} "$previous" "$all_settings"; then
      echo "stalwart: some dropped settings remain; the next start retries retracting them" >&2
    else
      install -m 600 "$all_settings" "$record"
    fi
    accounts=(${lib.escapeShellArgs (map (account: account.canonical) addressing.accounts)})
    for account in "''${accounts[@]}"; do
      install_sieve_stub "$account" ${stub-name} ${stub}
    done
  '';
}
