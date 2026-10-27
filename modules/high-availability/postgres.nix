{ config, lib, pkgs, ... }:

# A replicated Postgres beside each host's local cluster

let
  cfg = config.services.ha.postgres;
  inherit (config.site.ha) primary members preference voters ports;
  this-host = config.site.server.host;
  package = pkgs.postgresql_18;
  data-dir = "/var/lib/postgresql-ha/${package.psqlSchema}";
  address = host: "[${config.site.mesh.addresses.${host}}]";
  setup-sql = pkgs.writeText "postgresql-ha-setup.sql" (''
    \set ON_ERROR_STOP on
    SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') \gexec
    \set password `cat "$CREDENTIALS_DIRECTORY/replication"`
    ALTER ROLE replicator PASSWORD :'password';
  '' + lib.concatMapStrings (db: ''
    SELECT 'CREATE ROLE "${db}" LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}') \gexec
    SELECT 'CREATE DATABASE "${db}" OWNER "${db}"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}') \gexec
    ALTER ROLE "${db}" ${if lib.elem db cfg.local-commits then "SET synchronous_commit = local" else "RESET synchronous_commit"};
  '') cfg.databases);
  psql = "${package}/bin/psql -h ${cfg.socket-dir} -p ${toString ports.postgres} -d postgres";
  patroni-api = "http://${address this-host}:${toString ports.patroni}";
  leads = pkgs.writeShellScript "postgresql-ha-leads" ''
    ${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 3 ${patroni-api}/primary
  '';
  primary-env = cfg.primary-env;
in {
  options.services.ha.postgres = {
    primary-env = lib.mkOption {
      type = lib.types.str;
      default = "/run/postgresql-ha-role/primary.env";
      readOnly = true;
      description = "Environment file naming the leading host as HA_PRIMARY, kept by each member's watcher";
    };
    socket-dir = lib.mkOption {
      type = lib.types.str;
      default = "/run/postgresql-ha";
      readOnly = true;
      description = "Directory of the replicated Postgres's socket, through which services connect by peer authentication";
    };
    databases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Databases, each owned by a role of its name, so the service using it
        runs as a system user of that name.
      '';
    };
    follow-primary = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "lldap" ];
      description = "Services run only while this host's instance leads, once its databases exist";
    };
    track-primary = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "authelia-main" ];
      description = "Services given the leading host's name as $HA_PRIMARY, and restarted when it changes";
    };
    local-commits = lib.mkOption {
      type = lib.types.listOf (lib.types.enum cfg.databases);
      default = [ ];
      description = ''
        Databases whose commits return without waiting for a standby, for
        writes cheap to lose in a failover but costly to wait on: the nearest
        standby may be a continent away.
      '';
    };
  };

  config = lib.mkIf (primary != null && lib.elem this-host members) (lib.mkMerge [ {
    site.status.units = [ {
      id = "postgresql-ha";
      name = "Replicated Postgres";
      unit = "patroni.service";
      command = [ "${package}/bin/pg_isready" "--quiet" "--host=${cfg.socket-dir}" "--port=${toString ports.postgres}" ];
    } ];

    age.secrets.postgresql-ha-replication = {
      file = ../../secrets/keys/postgresql-ha-replication.age;
      owner = "postgres";
    };

    # the local cluster's module declares these where it runs
    users = lib.mkIf (!config.services.postgresql.enable) {
      users.postgres = {
        isSystemUser = true;
        group = "postgres";
        uid = config.ids.uids.postgres;
      };
      groups.postgres.gid = config.ids.gids.postgres;
    };

    # 113 for ident
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ ports.postgres ports.patroni 113 ];

    systemd.tmpfiles.settings."10-postgresql-ha" = {
      "/var/lib/patroni".d = { user = "postgres"; group = "postgres"; mode = "0700"; };
      "/var/lib/postgresql-ha".d = { user = "postgres"; group = "postgres"; mode = "0700"; };
    } // lib.optionalAttrs config.services.patroni.softwareWatchdog {
      # the module's udev rule misses a watchdog that already exists
      "/dev/watchdog".z = { user = "postgres"; group = "postgres"; mode = "0600"; };
    };

    services.patroni = {
      enable = true;
      user = "postgres";
      group = "postgres";
      scope = "ha";
      name = this-host;
      nodeIp = address this-host;
      postgresqlPackage = package;
      postgresqlDataDir = data-dir;
      postgresqlPort = ports.postgres;
      restApiPort = ports.patroni;
      softwareWatchdog = lib.elem this-host preference;
      settings = {
        etcd3.hosts = map (host: "${address host}:${toString ports.etcd}") voters;
        # only read once; later changes go through `patronictl edit-config`
        bootstrap.dcs = {
          ttl = 60;
          loop_wait = 10;
          retry_timeout = 20;
          synchronous_mode = "quorum";
          synchronous_node_count = 1;
          synchronous_mode_strict = false;
          failsafe_mode = true;
          postgresql = {
            use_pg_rewind = false;
            use_slots = true;
            parameters = {
              wal_level = "replica";
              hot_standby = "on";
              max_wal_senders = 10;
              max_replication_slots = 10;
              max_slot_wal_keep_size = "2GB";
            };
          };
        };
        postgresql = {
          listen = lib.mkForce "*:${toString ports.postgres}";
          use_unix_socket = true;
          remove_data_directory_on_diverged_timelines = true;
          remove_data_directory_on_rewind_failure = true;
          authentication = {
            superuser.username = "postgres";
            replication.username = "replicator";
            rewind.username = "replicator";
          };
          pg_hba = [
            "local all all peer"
            "host replication replicator ${config.site.mesh.subnet}/64 scram-sha-256"
            "host postgres replicator ${config.site.mesh.subnet}/64 scram-sha-256"
            "host all all ${config.site.mesh.subnet}/64 ident"
          ];
          parameters = {
            unix_socket_directories = cfg.socket-dir;
            shared_buffers = "32MB";
          };
        };
        tags = if lib.elem this-host preference
          then { failover_priority = lib.length preference - lib.lists.findFirstIndex (h: h == this-host) 0 preference; }
          else { nofailover = true; };
      };
    };

    systemd.services.patroni = let
      config-file = config.environment.sessionVariables.PATRONICTL_CONFIG_FILE;
      secret = config.age.secrets.postgresql-ha-replication.path;
    in {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-networkd.service" ];
      # restarting the leader would fail over; a reload rereads the path
      # Patroni started with, so that is the stable /etc one
      reloadIfChanged = true;
      restartTriggers = [ config.environment.etc.${lib.removePrefix "/etc/" config-file}.source ];
      script = lib.mkForce ''
        export PATRONI_REPLICATION_PASSWORD="$(< ${secret})" PATRONI_REWIND_PASSWORD="$(< ${secret})"
        exec ${lib.getExe pkgs.patroni} ${config-file}
      '';
      serviceConfig = {
        RuntimeDirectory = "postgresql-ha";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        MemorySwapMax = 0;
      };
    };

    systemd.targets.postgresql-ha-primary.description = "This host's replicated Postgres leads";

    systemd.services.postgresql-ha-role = {
      description = "Follow where the replicated PostgreSQL leads";
      wantedBy = [ "multi-user.target" ];
      after = [ "patroni.service" ];
      path = [ config.systemd.package pkgs.curl pkgs.jq ];
      # stops only after 30 s of misses, outlasting blips and adoption
      script = ''
        misses=0
        while :; do
          if ${leads}; then
            misses=0
            systemctl start --no-block postgresql-ha-primary.target
          elif [ $((++misses)) -ge 6 ]; then
            systemctl stop --no-block postgresql-ha-primary.target
          fi
          primary=$(curl -sf --max-time 3 ${patroni-api}/cluster | jq -r '.members[] | select(.role == "leader") | .name')
          if [ -n "$primary" ] && [ "HA_PRIMARY=$primary" != "$(cat ${primary-env} 2>/dev/null)" ]; then
            echo "HA_PRIMARY=$primary" > ${primary-env}
            ${lib.optionalString (cfg.track-primary != [ ]) "systemctl try-restart --no-block ${toString cfg.track-primary}"}
          fi
          systemd-notify --ready
          sleep 5
        done
      '';
      serviceConfig = {
        # ready once it has looked, so trackers start knowing the primary
        Type = "notify";
        NotifyAccess = "all";
        Restart = "always";
        RuntimeDirectory = "postgresql-ha-role";
        RuntimeDirectoryPreserve = true;
      };
    };

    services.oidentd.enable = true;
    systemd.services.oidentd = {
      after = [ "systemd-networkd.service" ];
      script = lib.mkForce "${pkgs.oidentd}/sbin/oidentd -u oidentd -g nogroup -a ${config.site.mesh.addresses.${this-host}}";
    };

    systemd.services.postgresql-ha-setup = {
      description = "Roles and databases of the replicated PostgreSQL";
      wantedBy = [ "postgresql-ha-primary.target" ];
      partOf = [ "postgresql-ha-primary.target" ];
      after = [ "patroni.service" ];
      script = "${psql} -f ${setup-sql}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        LoadCredential = [ "replication:${config.age.secrets.postgresql-ha-replication.path}" ];
        # skipped, not failed, where a deploy restarts it off the leader
        ExecCondition = leads;
      };
    };
  } {
    systemd.services = lib.genAttrs cfg.follow-primary (_: {
      wantedBy = lib.mkForce [ "postgresql-ha-primary.target" ];
      partOf = [ "postgresql-ha-primary.target" ];
      requires = [ "postgresql-ha-setup.service" ];
      after = [ "postgresql-ha-setup.service" ];
      serviceConfig.ExecCondition = leads;
    });
  } {
    systemd.services = lib.genAttrs cfg.track-primary (_: {
      wants = [ "postgresql-ha-role.service" "oidentd.service" ];
      after = [ "postgresql-ha-role.service" "oidentd.service" ];
      serviceConfig.EnvironmentFile = "-${primary-env}";
    });
  } ]);
}
