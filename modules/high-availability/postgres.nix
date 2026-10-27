{ config, lib, pkgs, ... }:

# A second Postgres instance holding the state that must outlive any one
# host, replicated over the mesh beside each host's local cluster. One host,
# site.ha.primary, takes writes; every other member streams from
# it as a hot standby through its own replication slot, cloning itself from
# the primary when its data directory is empty. Failover is manual: promote
# a standby, then name it primary.

let
  cfg = config.services.ha.postgres;
  inherit (config.site.ha) primary members;
  this-host = config.site.server.host;
  is-primary = this-host == primary;
  standbys = lib.remove primary members;
  package = pkgs.postgresql_18;
  port = config.site.ha.ports.postgres;
  data-dir = "/var/lib/postgresql-ha/${package.psqlSchema}";
  socket-dir = cfg.socket-dir;
  # a slot name allows only lower-case letters, digits and underscores
  slot = host: lib.replaceStrings [ "-" ] [ "_" ] host;
  # replication connects with the agenix password; a wildcard pgpass entry
  # spares escaping the colons of an IPv6 host
  pgpass = "${socket-dir}/pgpass";
  write-pgpass = ''
    install -m 0600 /dev/null ${pgpass}
    printf '*:*:*:replicator:%s\n' "$(cat "$CREDENTIALS_DIRECTORY/replication")" > ${pgpass}
  '';
  conf = pkgs.writeText "postgresql-ha.conf" ''
    listen_addresses = '*'
    port = ${toString port}
    unix_socket_directories = '${socket-dir}'
    shared_buffers = '32MB'
    wal_level = replica
    max_wal_senders = 10
    max_replication_slots = 10
    # a standby gone for good may hold back this much WAL, no more
    max_slot_wal_keep_size = '2GB'
    hot_standby = on
    primary_conninfo = 'host=${primary}.internal port=${toString port} user=replicator passfile=${pgpass} application_name=${slot this-host}'
    primary_slot_name = '${slot this-host}'
    log_destination = 'stderr'
    log_line_prefix = '%m [%p] '
  '';
  hba = pkgs.writeText "pg_hba.conf" ''
    local all all peer
    host replication replicator ${config.site.mesh.subnet}/64 scram-sha-256
  '';
  setup-sql = pkgs.writeText "postgresql-ha-setup.sql" (''
    \set ON_ERROR_STOP on
    SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') \gexec
    \set password `cat "$CREDENTIALS_DIRECTORY/replication"`
    ALTER ROLE replicator PASSWORD :'password';
  '' + lib.concatMapStrings (host: ''
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = '${slot host}') THEN
        PERFORM pg_create_physical_replication_slot('${slot host}');
      END IF;
    END $$;
  '') standbys + lib.concatMapStrings (db: ''
    SELECT 'CREATE ROLE "${db}" LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}') \gexec
    SELECT 'CREATE DATABASE "${db}" OWNER "${db}"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}') \gexec
  '') cfg.databases);
  primary-prepare = ''
    if [ ! -e ${data-dir}/PG_VERSION ]; then
      initdb -D ${data-dir} --encoding=UTF8 --locale=C.UTF-8
    fi
  '';
  # An empty standby clones the primary, beside its data directory until
  # complete, so an interrupted clone never looks like data. Data without
  # standby.signal was a primary's: starting it could make a second
  # primary, so the standby refuses until it is moved aside.
  standby-prepare = ''
    if [ ! -e ${data-dir}/PG_VERSION ]; then
      rm -rf ${data-dir}.clone
      PGPASSFILE=${pgpass} pg_basebackup -h ${primary}.internal -p ${toString port} \
        -U replicator -D ${data-dir}.clone -X stream -S ${slot this-host}
      touch ${data-dir}.clone/standby.signal
      rmdir ${data-dir}
      mv ${data-dir}.clone ${data-dir}
    elif [ ! -e ${data-dir}/standby.signal ]; then
      echo "${data-dir} holds a primary's data, and ${primary} is primary;" \
        "move it aside to clone afresh once ${primary} is confirmed" >&2
      exit ${toString refused}
    fi
  '';
  refused = 3;
in {
  options.services.ha.postgres = {
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
        Databases the primary ensures, each owned by a login role of the same
        name that connects over the socket by peer authentication, so the
        service using it runs as a system user of that name.
      '';
    };
  };

  config = lib.mkIf (primary != null && lib.elem this-host members) {
    site.status.units = [ {
      id = "postgresql-ha";
      name = if is-primary then "Postgres primary" else "Postgres replica";
      unit = "postgresql-ha.service";
      command = [ "${package}/bin/pg_isready" "--quiet" "--host=${socket-dir}" "--port=${toString port}" ];
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

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ port ];

    systemd.services.postgresql-ha = {
      description = "Replicated PostgreSQL (${if is-primary then "primary" else "standby of ${primary}"})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-networkd.service" ];
      # a standby whose primary is unreachable keeps retrying its clone
      unitConfig.StartLimitIntervalSec = 0;
      path = [ package ];
      preStart = write-pgpass + (if is-primary then primary-prepare else standby-prepare);
      serviceConfig = {
        Type = "notify";
        User = "postgres";
        Group = "postgres";
        RuntimeDirectory = "postgresql-ha";
        RuntimeDirectoryMode = "0755";
        StateDirectory = "postgresql-ha postgresql-ha/${package.psqlSchema}";
        StateDirectoryMode = "0700";
        LoadCredential = [ "replication:${config.age.secrets.postgresql-ha-replication.path}" ];
        ExecStart = "${package}/bin/postgres -D ${data-dir} -c config_file=${conf} -c hba_file=${hba}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        KillSignal = "SIGINT";
        KillMode = "mixed";
        TimeoutSec = 120;
        # a clone runs before the server starts, and grows with the data
        TimeoutStartSec = "30min";
        Restart = "on-failure";
        RestartSec = "30s";
        RestartPreventExitStatus = [ refused ];
      };
    };

    systemd.services.postgresql-ha-setup = lib.mkIf is-primary {
      description = "Roles, slots and databases of the replicated PostgreSQL";
      wantedBy = [ "postgresql-ha.service" ];
      after = [ "postgresql-ha.service" ];
      requires = [ "postgresql-ha.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        LoadCredential = [ "replication:${config.age.secrets.postgresql-ha-replication.path}" ];
        ExecStart = "${package}/bin/psql -h ${socket-dir} -p ${toString port} -d postgres -f ${setup-sql}";
      };
    };
  };
}
