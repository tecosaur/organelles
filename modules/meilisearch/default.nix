{ config, lib, pkgs, ... }:

# One Meilisearch, shared over the mesh. Each client holds a key scoped to its own indexes:
# Meilisearch derives a key as the HMAC of its uid under the master key, so init-keys.sh
# computes it ahead from the committed uid, and meilisearch-keys need only declare it. The
# master key never leaves the Meilisearch host.

let
  inherit (config.site.meilisearch) host url keys;
  inherit (config.site.ports.meilisearch) port;
  uid = name: lib.removeSuffix "\n" (builtins.readFile (../../secrets/keys + "/meilisearch-${name}.uid"));
  # Named site:<name>, so keys no longer declared are recognised and removed
  wanted = lib.mapAttrsToList (name: indexes: {
    uid = uid name;
    name = "site:${name}";
    inherit indexes;
    actions = [ "*" ];
    expiresAt = null;
  }) keys;
  declare-keys = pkgs.writeShellApplication {
    name = "meilisearch-keys";
    runtimeInputs = with pkgs; [ curl jq ];
    text = ''
      api() {
        curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s' "$(< "$CREDENTIALS_DIRECTORY/master-key")") \
          -H 'Content-Type: application/json' "$@"
      }
      tries=0
      until curl -sf -o /dev/null ${url}/health; do
        [ $((tries += 1)) -le 60 ] || { echo "meilisearch-keys: ${url} did not answer within a minute" >&2; exit 1; }
        sleep 1
      done
      want=${lib.escapeShellArg (builtins.toJSON wanted)}
      current=$(api "${url}/keys?limit=1000")
      # A key's scope cannot be edited, but recreating it under its uid gives the same key
      jq -r --argjson want "$want" '.results[] | select(.name // "" | startswith("site:"))
        | select(. as $key | $want | all(. != ($key | {uid, name, indexes, actions, expiresAt}))) | .uid' <<<"$current" |
        while read -r stale; do api -X DELETE "${url}/keys/$stale" >/dev/null; done
      jq -c --argjson want "$want" '[.results[] | {uid, name, indexes, actions, expiresAt}] as $have
        | $want[] | select(IN($have[]) | not)' <<<"$current" |
        while read -r key; do api -X POST "${url}/keys" --data-binary "$key" >/dev/null; done
    '';
  };
in {
  config = lib.mkIf (config.site.server.host == host) {
    age.secrets.meilisearch-master.file = ../../secrets/keys/meilisearch-master.age;
    services.meilisearch = {
      enable = true;
      listenAddress = "[${config.site.mesh.addresses.${host}}]";
      listenPort = port;
      masterKeyFile = config.age.secrets.meilisearch-master.path;
      settings.env = "production";
    };
    systemd.services.meilisearch = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-networkd.service" ];
      serviceConfig = {
        IPAddressAllow = [ "localhost" "${config.site.mesh.subnet}/64" ];
        IPAddressDeny = "any";
        # wg0 may not carry its address when the socket binds
        RestartSec = "10s";
      };
      startLimitIntervalSec = 0;
    };
    systemd.services.meilisearch-keys = {
      description = "Declare each Meilisearch client's scoped key";
      wantedBy = [ "multi-user.target" ];
      requires = [ "meilisearch.service" ];
      after = [ "meilisearch.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe declare-keys;
        LoadCredential = "master-key:${config.age.secrets.meilisearch-master.path}";
        DynamicUser = true;
      };
    };
    site.status.units = [ { id = "meilisearch"; name = "Meilisearch"; unit = "meilisearch.service"; } ];
  };
}
