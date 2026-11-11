{ config, lib, pkgs, ... }:

# This host's side of the shared databases (site.nix): how its units find the primary, and, kept
# unreplicated, the host's own Postgres and a Valkey serving it.

let
  cfg = config.services.databases;
  databases = config.site.databases;
  this-host = config.site.server.host;
  address = host: config.site.mesh.addresses.${host};
  trackers = lib.unique (cfg.track-primary ++ cfg.follow-primary);
  beside-primary = lib.filter (app: app.followsPrimary && app.hosts != [ ]) (lib.attrValues config.site.apps);
  names = description: lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; inherit description; };
in {
  options.services.databases = {
    track-primary = names "Services given site.databases.servers.primary-env, and restarted when the primary moves";
    follow-primary = names "Services run only on the serving host, once its databases exist, given primary-env";
    follow-primary-sockets = names "Sockets listening on the serving host alone, for services reached beside the primary";
    postgres.probe-roles = names "Login roles for the system users whose probes connect by peer authentication";
  };

  config = lib.mkMerge [
    {
      # site.apps' followsPrimary, every Caddy proxying to wherever it runs
      services.databases.follow-primary = map (app: app.service) (lib.filter (app: lib.elem this-host app.hosts) beside-primary);
      assertions = map (app: {
        assertion = lib.all (host: lib.elem host app.hosts) databases.hosts;
        message = "${app.name} runs beside the primary, so must be on every host in site.databases.hosts (${toString databases.hosts}), not only ${toString app.hosts}";
      }) beside-primary;
      systemd.services = lib.genAttrs trackers (_: { serviceConfig.EnvironmentFile = "-${databases.servers.primary-env}"; });
    }
    # Postgres authenticates a client over the mesh by asking its host who holds the connection
    (lib.mkIf (lib.any (lib.elem this-host) (lib.attrValues config.site.ports.postgres.clients)) {
      services.oidentd.enable = true;
      systemd.services.oidentd.script = lib.mkForce "${pkgs.oidentd}/sbin/oidentd -u oidentd -g nogroup -a ${address this-host}";
    })
    (lib.mkIf (!databases.replicated && databases.primary != null) {
      environment.etc.${lib.removePrefix "/etc/" databases.servers.primary-env}.text = ''
        DB_PRIMARY=${databases.primary}
        DB_SERVING=${databases.primary}
        PGHOST=${databases.primary}.internal
        PGPORT=${toString config.site.ports.postgres.port}
      '';
      systemd.services = lib.genAttrs trackers (_: {
        wants = [ "oidentd.service" "postgresql-setup.service" ];
        after = [ "oidentd.service" "postgresql-setup.service" ];
      });
    })
    (lib.mkIf (!databases.replicated && databases.may-serve) {
      systemd.sockets = lib.genAttrs cfg.follow-primary-sockets (_: { wantedBy = [ "sockets.target" ]; });
      services.postgresql = {
        enable = true;
        enableTCPIP = true;
        ensureDatabases = lib.attrNames databases.postgres;
        ensureUsers = map (name: { inherit name; ensureDBOwnership = true; }) (lib.attrNames databases.postgres);
        authentication = lib.concatMapStrings (host: "host sameuser all ${address host}/128 ident\n")
          (lib.unique (lib.concatLists (lib.attrValues config.site.ports.postgres.clients)));
      };
      services.redis.servers.shared = {
        enable = true;
        bind = "${address this-host} 127.0.0.1";
        inherit (config.site.ports.valkey) port;
        # read as root
        requirePassFile = config.site.secrets.valkey-default.decrypted;
        appendOnly = true;
      };
      systemd.services.redis-shared = {
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
      };
    })
  ];
}
