{ config, lib, pkgs, ... }:

# A replicated Postgres beside each host's local cluster (HA.md §8)

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
  '') (lib.attrNames cfg.databases));
  psql = "${package}/bin/psql -h ${cfg.socket-dir} -p ${toString ports.postgres} -d postgres";
  leads = pkgs.writeShellScript "postgresql-ha-leads" ''
    ${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 3 http://${address this-host}:${toString ports.patroni}/primary
  '';
in {
  options.services.ha.postgres = {
    socket-dir = lib.mkOption {
      type = lib.types.str;
      default = "/run/postgresql-ha";
      readOnly = true;
      description = "Directory of the replicated Postgres's socket, through which services connect by peer authentication";
    };
    databases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { lldap = "lldap"; };
      description = ''
        Databases, each mapped to the service using it. A database is owned
        by a role of its name that connects over the socket by peer
        authentication, so its service runs as a system user of that name,
        and only while this host's instance leads.
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

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ ports.postgres ports.patroni ];

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
      description = "Start or stop what needs the replicated PostgreSQL to lead here";
      wantedBy = [ "multi-user.target" ];
      after = [ "patroni.service" ];
      path = [ config.systemd.package ];
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
          sleep 5
        done
      '';
      serviceConfig.Restart = "always";
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
    systemd.services = lib.mapAttrs' (_: service: lib.nameValuePair service {
      wantedBy = lib.mkForce [ "postgresql-ha-primary.target" ];
      partOf = [ "postgresql-ha-primary.target" ];
      requires = [ "postgresql-ha-setup.service" ];
      after = [ "postgresql-ha-setup.service" ];
    }) cfg.databases;
  } ]);
}
