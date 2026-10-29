{ config, lib, pkgs, ... }:

# Mail bodies live in the primary Garage, and the overflow cluster keeps what the primary
# cannot take while it is down. No host runs both. A meshed cluster's node keys are
# pre-generated, so its peers are declared; a lone node, on loopback, makes its own key and
# RPC secret.

let
  inherit (lib) attrNames length mapAttrs;
  this-host = config.site.server.host;
  package = pkgs.garage_2;
  region = "garage";
  inherit (config.site.mail) storage ports;
  keys = ../../secrets/keys;
  address = host: config.site.mesh.addresses.${host};
  sidecar = name: lib.removeSuffix "\n" (builtins.readFile (keys + "/${name}"));
  node-id = host: sidecar "garage-node-${host}.pub";
  cluster-of = capacity-bytes: rec {
    inherit capacity-bytes;
    # Every node holds a copy
    replication-factor = length (attrNames capacity-bytes);
    # Serves S3 to the mesh and applies layouts: the member likeliest to run a gateway
    head-host = lib.findFirst (host: capacity-bytes ? ${host}) (lib.head (attrNames capacity-bytes)) config.site.ha.preference;
  };
  clusters = {
    primary = cluster-of storage.primary // {
      db-engine = "sqlite";
      root = "/data/garage";
      ports = { s3 = ports.garage-primary-s3; rpc = ports.garage-primary-rpc; };
      bucket = "mail";
      quota-bytes = null;
      key = { name = "mail-primary"; id = sidecar "garage-mail-primary.id"; };
    };
    overflow = cluster-of storage.overflow // {
      # Each node can rebuild LMDB from the other after an unclean shutdown
      db-engine = "lmdb";
      root = "/var/lib/garage-overflow";
      ports = { s3 = ports.garage-overflow-s3; rpc = ports.garage-overflow-rpc; };
      bucket = "mail-overflow";
      quota-bytes = storage.overflow-quota-bytes;
      key = { name = "mail-overflow"; id = sidecar "garage-mail-overflow.id"; };
    };
  };
  hosts-of = cluster: attrNames cluster.capacity-bytes;
  this-cluster-name = lib.findFirst (name: lib.elem this-host (hosts-of clusters.${name})) null (attrNames clusters);
  cluster = clusters.${this-cluster-name};
  is-meshed = length (hosts-of cluster) > 1;
  rpc-addr = host:
    if is-meshed then "[${address host}]:${toString cluster.ports.rpc}"
    else "127.0.0.1:${toString cluster.ports.rpc}";
  meta-dir = "${cluster.root}/meta";
  rpc-secret = if is-meshed then config.age.secrets."garage-${this-cluster-name}-rpc".path else "${meta-dir}/rpc_secret";
  # node_key is libsodium's 64-byte ed25519 secret key; the CLI reads the node ID from node_key.pub
  install-node-key = pkgs.writeShellScript "garage-node-key" ''
    set -euo pipefail
    key="$CREDENTIALS_DIRECTORY/node-key"
    public=$(base64 -d "$key" | tail -c 32 | od -An -tx1 -v | tr -d ' \n')
    if [ "$public" != ${node-id this-host} ]; then
      echo "garage: keys/garage-node-${this-host}.age does not hold the key keys/garage-node-${this-host}.pub names; regenerate both with init-keys.sh" >&2
      exit 1
    fi
    umask 077
    base64 -d "$key" > ${meta-dir}/node_key
    base64 -d "$key" | tail -c 32 > ${meta-dir}/node_key.pub
  '';
  generate-rpc-secret = pkgs.writeShellScript "garage-rpc-secret" ''
    [ -s ${rpc-secret} ] || (umask 077; ${lib.getExe pkgs.openssl} rand -hex 32 > ${rpc-secret})
  '';
  # A lone node's key is its own, so the setup reads its ID at runtime
  roles = map (host: {
    id = if is-meshed then node-id host else null;
    zone = host;
    capacity = cluster.capacity-bytes.${host};
    tags = [ ];
  }) (hosts-of cluster);
  setup = pkgs.writeShellScript "garage-mail-setup" ''
    set -euo pipefail
    api() { garage json-api "$@"; }
    # Waiting on a node is routine (a peer not yet deployed), so it ends the run cleanly for the timer to retry
    await() {
      local what="$1" deadline=$((SECONDS + 30))
      shift
      until "$@"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "garage-mail-setup: $what not up; will retry"
          exit 0
        fi
        sleep 2
      done
    }
    answers() { api GetClusterHealth >/dev/null 2>&1; }
    healthy() { [ "$(api GetClusterHealth 2>/dev/null | jq -r .status)" = healthy ]; }
    await "local Garage" answers
    # Layout: the declared roles, and no others
    self=$(garage node id -q | cut -d@ -f1)
    want=$(jq --arg self "$self" 'map(.id //= $self)' <<<${lib.escapeShellArg (builtins.toJSON roles)})
    layout=$(api GetClusterLayout)
    if ! jq -e --argjson want "$want" \
        '([.roles[] | {id, zone, capacity, tags}] | sort_by(.id)) == ($want | sort_by(.id)) and .stagedRoleChanges == []' \
        <<<"$layout" >/dev/null; then
      jq --argjson want "$want" '{roles: ($want + ([(.roles + .stagedRoleChanges)[].id] | unique
          | map(select(. as $id | $want | all(.id != $id)) | {id: ., remove: true})))}' <<<"$layout" |
        api UpdateClusterLayout - >/dev/null
      api ApplyClusterLayout "{\"version\": $(( $(jq .version <<<"$layout") + 1 ))}" | jq -r '.message[]'
    fi
    await "peer" healthy
    bucket=$(api GetBucketInfo '{"globalAlias": "${cluster.bucket}"}' 2>/dev/null | jq -r .id) ||
      bucket=$(api CreateBucket '{"globalAlias": "${cluster.bucket}"}' | jq -r .id)
    jq -n --arg id "$bucket" '{id: $id, body: {quotas: {maxSize: ${builtins.toJSON cluster.quota-bytes}, maxObjects: null}}}' |
      api UpdateBucket - >/dev/null
    # Key, imported so its secret can live in agenix; a deleted ID can never be imported again
    secret="$CREDENTIALS_DIRECTORY/key-secret"
    if key=$(api GetKeyInfo '{"id": "${cluster.key.id}", "showSecretKey": true}' 2>/dev/null); then
      if ! jq -e --rawfile secret "$secret" '.secretAccessKey == ($secret | rtrimstr("\n"))' <<<"$key" >/dev/null; then
        echo "garage-mail-setup: key ${cluster.key.id} holds a secret other than keys/garage-${cluster.key.name}.age's;" \
          "Garage cannot change an imported secret, so give the key a new ID in modules/mail/garage.nix" >&2
        exit 1
      fi
    else
      jq -n --rawfile secret "$secret" \
        '{accessKeyId: "${cluster.key.id}", secretAccessKey: ($secret | rtrimstr("\n")), name: "${cluster.key.name}"}' |
        api ImportKey - >/dev/null
    fi
    jq -n --arg bucket "$bucket" \
      '{bucketId: $bucket, accessKeyId: "${cluster.key.id}", permissions: {read: true, write: true, owner: false}}' |
      api AllowBucketKey - >/dev/null
  '';
  secret = name: { file = keys + "/garage-${name}.age"; };
in {
  options.site.mail.garage = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    readOnly = true;
    default = mapAttrs (_: c: {
      inherit (c) bucket quota-bytes;
      inherit region;
      access-key-id = c.key.id;
      secret-file = (secret c.key.name).file;
      endpoint = host: if lib.elem host (hosts-of c)
        then "http://127.0.0.1:${toString c.ports.s3}"
        else "http://${c.head-host}.internal:${toString c.ports.s3}";
    }) clusters;
    description = ''
      The mail buckets by cluster (primary, overflow), each with its quota,
      region, client key and `endpoint host`, the S3 URL to reach it by
      from that host.
    '';
  };
  config = lib.mkIf (this-cluster-name != null) (lib.mkMerge [
    {
      age.secrets = lib.mkIf is-meshed {
        # Garage refuses a secret its owner alone cannot read, so not systemd's 0440 credential copy
        "garage-${this-cluster-name}-rpc" = secret "${this-cluster-name}-rpc" // { owner = "garage"; };
        "garage-node-${this-host}" = secret "node-${this-host}";
      };
      users.users.garage = {
        isSystemUser = true;
        group = "garage";
      };
      users.groups.garage = { };
      # The unit may bind meta and data read-write, so they must exist before it starts
      systemd.tmpfiles.rules = map (dir: "d ${dir} 0700 garage garage -") [ cluster.root meta-dir "${cluster.root}/data" ];
      services.garage = {
        enable = true;
        inherit package;
        settings = {
          replication_factor = cluster.replication-factor;
          consistency_mode = "consistent";
          db_engine = cluster.db-engine;
          metadata_dir = meta-dir;
          data_dir = "${cluster.root}/data";
          # Mail is acknowledged once written, so the write must survive power loss
          metadata_fsync = true;
          data_fsync = true;
          rpc_bind_addr = rpc-addr this-host;
          rpc_public_addr = rpc-addr this-host;
          # Read by the daemon and, as root, by the CLI
          rpc_secret_file = rpc-secret;
          bootstrap_peers = map (host: "${node-id host}@${rpc-addr host}")
            (lib.remove this-host (hosts-of cluster));
          # [::] answers on loopback and wg0, and the firewall opens only wg0
          s3_api = {
            s3_region = region;
            api_bind_addr = if cluster.head-host == this-host
              then "[::]:${toString cluster.ports.s3}"
              else "127.0.0.1:${toString cluster.ports.s3}";
          };
        } // lib.optionalAttrs (cluster.db-engine == "lmdb") {
          metadata_auto_snapshot_interval = "6h";
        };
      };
      systemd.services.garage = {
        unitConfig.RequiresMountsFor = [ cluster.root ];
        serviceConfig = {
          DynamicUser = false;
          User = "garage";
          Group = "garage";
          StateDirectory = lib.mkForce [ ];
          LoadCredential = lib.optional is-meshed "node-key:${config.age.secrets."garage-node-${this-host}".path}";
          ExecStartPre = [ (if is-meshed then install-node-key else generate-rpc-secret) ];
          # wg0 may not carry its address yet when the RPC socket binds;
          # anything lasting past ~2 minutes is a real fault
          Restart = "always";
          RestartSec = "10s";
        };
        startLimitBurst = 12;
        startLimitIntervalSec = 300;
      };
      networking.firewall.interfaces.wg0.allowedTCPPorts =
        lib.optional is-meshed cluster.ports.rpc
        ++ lib.optional (cluster.head-host == this-host) cluster.ports.s3;
      site.status.units = [ { id = "garage"; name = "Garage mail ${this-cluster-name}"; unit = "garage.service"; } ];
    }
    (lib.mkIf (cluster.head-host == this-host) {
      age.secrets."garage-${cluster.key.name}" = secret cluster.key.name;
      systemd.services.garage-mail-setup = {
        description = "Declare the ${this-cluster-name} Garage cluster's layout, bucket and key";
        after = [ "garage.service" ];
        path = [ package pkgs.jq ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = setup;
          LoadCredential = [ "key-secret:${config.age.secrets."garage-${cluster.key.name}".path}" ];
        };
      };
      # Kept out of activation, which must not wait on a peer not yet deployed;
      # a changed script restarts the timer, and OnActiveSec runs it soon after
      systemd.timers.garage-mail-setup = {
        wantedBy = [ "timers.target" ];
        restartTriggers = [ setup ];
        timerConfig = {
          OnActiveSec = "30s";
          OnBootSec = "1min";
          OnUnitInactiveSec = "5min";
        };
      };
    })
  ]);
}
