{ config, lib, pkgs, ... }:

# The S3 gateway beside each Stalwart; gateways on several hosts share locks (Postgres) and
# heat (Valkey).

let
  inherit (config.site) databases ports;
  this-host = config.site.server.host;
  package = pkgs.callPackage ./packages/s3-overflow.nix { };
  garage = config.site.mail.garage;
  user = "s3-overflow";
  mail-ports = config.site.apps.mail.ports;
  inherit (config.site.mail) storage;
  status-listen = "127.0.0.1:${toString mail-ports.s3-gateway-status.port}";
  max-object-bytes = 268435456;
  store-timeouts = { connect-seconds = 10; stall-seconds = 30; };
  # The slowest link a blob may cross
  slowest-link-bytes-per-second = 2000000;
  gateway = {
    endpoint = "http://127.0.0.1:${toString mail-ports.s3-gateway.port}";
    bucket = "mail";
    inherit (garage.primary) region;
    access-key-id = lib.removeSuffix "\n" (builtins.readFile ../../secrets/keys/s3-overflow-client.id);
    inherit max-object-bytes;
    # The largest PUT crosses the slowest link twice, and may wait out both stores' timeouts
    timeout-seconds = (2 * max-object-bytes + slowest-link-bytes-per-second - 1) / slowest-link-bytes-per-second
      + 2 * (store-timeouts.connect-seconds + store-timeouts.stall-seconds);
  };
  # The volume's budget holds a full overflow replica, the whole cache and the reserve
  caches = lib.mapAttrs (_: target-bytes: {
    dir = "/var/lib/s3-overflow";
    inherit target-bytes;
    reserve-bytes = 536870912;
    volume = "/var/lib";
  }) storage.cache-bytes;
  cache = lib.mapNullable (c: c // { budget-bytes = garage.overflow.quota-bytes + c.target-bytes + c.reserve-bytes; })
    (caches.${this-host} or null);
  secrets = {
    client = config.site.apps.mail.secrets.s3-overflow-client;
    primary = garage.primary.secret;
    overflow = garage.overflow.secret;
  } // lib.optionalAttrs databases.replicated {
    valkey = config.site.secrets.valkey-s3-overflow;
    # Sentinel takes the shared password, as the default user
    sentinel = config.site.secrets.valkey-default;
  };
  store = name: {
    endpoint = garage.${name}.endpoint this-host;
    inherit (garage.${name}) bucket region;
    access_key_id = garage.${name}.access-key-id;
    secret_access_key_file = secrets.${name}.credential-name;
    connect_timeout_seconds = store-timeouts.connect-seconds;
    stall_timeout_seconds = store-timeouts.stall-seconds;
  };
  settings = {
    listen = lib.removePrefix "http://" gateway.endpoint;
    status_listen = status-listen;
    inherit (gateway) bucket region;
    access_key_id = gateway.access-key-id;
    secret_access_key_file = secrets.client.credential-name;
    max_object_bytes = max-object-bytes;
    primary = store "primary";
    # Without this the bound is budget − reserve, beyond the bucket's quota
    overflow = store "overflow" // { max_bytes = garage.overflow.quota-bytes; };
    cache = if cache == null then { target_bytes = 0; } else {
      inherit (cache) dir;
      target_bytes = cache.target-bytes;
    };
  } // lib.optionalAttrs (cache != null) {
    storage = {
      budget_bytes = cache.budget-bytes;
      reserve_bytes = cache.reserve-bytes;
      inherit (cache) volume;
    };
  } // lib.optionalAttrs databases.replicated {
    coordination = {
      postgres = lib.concatStringsSep " " [
        "host=${lib.concatMapStringsSep "," (host: "${host}.internal") databases.servers.hosts}"
        "port=${toString ports.postgres.port}"
        "dbname=${user}"
        "user=${user}"
        "target_session_attrs=read-write"
      ];
      valkey = {
        sentinels = map (host: "${host}.internal:${toString ports.ha-sentinel.port}") config.site.ha.voters;
        master = "ha";
        username = user;
        password_file = secrets.valkey.credential-name;
        sentinel_password_file = secrets.sentinel.credential-name;
      };
    };
  };
  # check reads every secret, so placeholders stand in for the credentials
  config-file = pkgs.runCommand "s3-overflow.json" { nativeBuildInputs = [ package ]; } ''
    cp ${pkgs.writeText "s3-overflow.json" (builtins.toJSON settings)} $out
    export CREDENTIALS_DIRECTORY=$PWD/credentials
    mkdir $CREDENTIALS_DIRECTORY
    for name in ${toString (lib.mapAttrsToList (_: secret: secret.credential-name) secrets)}; do
      echo placeholder > $CREDENTIALS_DIRECTORY/$name
    done
    s3-overflow -config $out check
  '';
in {
  options.site.mail.gateway = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    readOnly = true;
    default = gateway;
    description = ''
      The S3 bucket Stalwart stores blobs in, on every host that may lead:
      its endpoint, region, client key, `max-object-bytes`, the largest blob
      it takes, and `timeout-seconds`, the least client timeout that lets
      the largest blob spill over the slowest link.
    '';
  };
  config = lib.mkIf databases.may-serve {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = { };
    systemd.services.s3-overflow = {
      description = "S3 gateway spilling mail blobs to the overflow while the primary is down";
      wantedBy = [ "multi-user.target" ];
      # It dials Postgres, which authenticates it by ident, Valkey and Garage over the mesh
      wants = [ "network-online.target" "wg0-online.service" ];
      after = [ "network-online.target" "wg0-online.service" "oidentd.service" "garage.service" ];
      sandboxed = true;
      serviceConfig = {
        ExecStart = "${lib.getExe package} -config ${config-file} serve";
        User = user;
        Group = user;
        Restart = "always";
        RestartSec = "5s";
        # Large bodies spool here
        RuntimeDirectory = "s3-overflow";
        RuntimeDirectoryMode = "0700";
        IPAddressDeny = "any";
        IPAddressAllow = [ "localhost" "${config.site.mesh.subnet}/64" ];
      } // lib.optionalAttrs (cache != null) {
        StateDirectory = "s3-overflow";
        StateDirectoryMode = "0700";
      };
    };
    site.status.units = [ {
      id = "s3-overflow";
      name = "S3 overflow gateway";
      unit = "s3-overflow.service";
      command = [ (lib.getExe pkgs.curl) "--silent" "--fail" "--output" "/dev/null" "--max-time" "3" "http://${status-listen}/status" ];
    } ];
  };
}
