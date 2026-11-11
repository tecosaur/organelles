{ config, lib, pkgs, ... }:

# The shared Postgres replicated, by Patroni, beside each host's local cluster

let
  cfg = config.services.databases;
  inherit (config.site.ha) members preference voters;
  inherit (config.site) ports;
  this-host = config.site.server.host;
  inherit (cfg.postgres) probe-roles;
  inherit (config.site.databases.servers) primary-env;
  inherit (config.site.databases.servers.postgres) socket-dir;
  package = pkgs.postgresql_18;
  data-dir = "/var/lib/postgresql-ha/${package.psqlSchema}";
  address = host: "[${config.site.mesh.addresses.${host}}]";
  setup-sql = pkgs.writeText "postgresql-ha-setup.sql" (''
    \set ON_ERROR_STOP on
    SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') \gexec
    \set password `cat "$CREDENTIALS_DIRECTORY/${config.site.secrets.postgresql-ha-replication.credential-name}"`
    ALTER ROLE replicator PASSWORD :'password';
  '' + lib.concatMapStrings (role: ''
    SELECT 'CREATE ROLE "${role}" LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') \gexec
  '') probe-roles
  # a durable commit waits for a standby's write, not its disk sync, which on the nearest is slow
  + lib.concatStrings (lib.mapAttrsToList (db: { local-commits, ... }: ''
    SELECT 'CREATE ROLE "${db}" LOGIN'
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}') \gexec
    SELECT 'CREATE DATABASE "${db}" OWNER "${db}"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}') \gexec
    REVOKE CONNECT, TEMPORARY ON DATABASE "${db}" FROM PUBLIC;
    ALTER ROLE "${db}" SET synchronous_commit = ${if local-commits then "local" else "remote_write"};
  '') config.site.databases.postgres));
  patroni-api = "http://${address this-host}:${toString ports.patroni.port}";
  serves = pkgs.writeShellScript "postgresql-ha-serves" ''
    grep -qx 'DB_SERVING=${this-host}' ${primary-env}
  '';
  # The members a leader here hands over to, once one has streamed for failback-minutes
  ahead = lib.take (lib.lists.findFirstIndex (h: h == this-host) (lib.length preference) preference) preference;
  trackers = lib.unique (cfg.track-primary ++ cfg.follow-primary);
in {
  config = lib.mkIf (config.site.databases.replicated && lib.elem this-host members) (lib.mkMerge [ {
    site.status.units = [ {
      id = "postgresql-ha";
      name = "Replicated Postgres";
      unit = "patroni.service";
      command = [ "${package}/bin/pg_isready" "--quiet" "--host=${socket-dir}" "--port=${toString ports.postgres.port}" "--dbname=postgres" ];
    } ];

    environment.systemPackages = [ (lib.hiPrio (pkgs.writeShellScriptBin "patronictl" ''
      if [ -r ${config.site.secrets.patroni-restapi.decrypted} ]; then
        export PATRONI_RESTAPI_USERNAME=patroni PATRONI_RESTAPI_PASSWORD="$(< ${config.site.secrets.patroni-restapi.decrypted})"
      fi
      exec ${pkgs.patroni}/bin/patronictl "$@"
    '')) ];

    # the local cluster's module declares these where it runs
    users = lib.mkIf (!config.services.postgresql.enable) {
      users.postgres = {
        isSystemUser = true;
        group = "postgres";
        uid = config.ids.uids.postgres;
      };
      groups.postgres.gid = config.ids.gids.postgres;
    };

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
      postgresqlPort = ports.postgres.port;
      restApiPort = ports.patroni.port;
      softwareWatchdog = true;
      settings = {
        etcd3.hosts = map (host: "${address host}:${toString ports.etcd.port}") voters;
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
          listen = lib.mkForce "*:${toString ports.postgres.port}";
          use_unix_socket = true;
          remove_data_directory_on_diverged_timelines = true;
          remove_data_directory_on_rewind_failure = true;
          authentication = {
            superuser.username = "postgres";
            replication.username = "replicator";
            rewind.username = "replicator";
          };
          # ident is believed only from the hosts that run apps: root on any other
          # member could otherwise vouch for any role
          pg_hba = [
            "local all postgres peer"
            "local sameuser all peer"
          ] ++ map (role: "local postgres \"${role}\" peer") probe-roles ++ [
            "host replication replicator ::1/128 scram-sha-256"
            "host replication replicator 127.0.0.1/32 scram-sha-256"
            "host replication replicator ${config.site.mesh.subnet}/64 scram-sha-256"
            "host postgres replicator ${config.site.mesh.subnet}/64 scram-sha-256"
          ] ++ map (host: "host all postgres ${config.site.mesh.addresses.${host}}/128 ident") preference ++ [
            "host all postgres all reject"
          ] ++ map (host: "host sameuser all ${config.site.mesh.addresses.${host}}/128 ident") preference;
          parameters = {
            unix_socket_directories = socket-dir;
            shared_buffers = "32MB";
          };
        };
        # Promotable, so its acknowledgements count: a member outside the preference leads only
        # when none in it can, and then until failback
        tags.failover_priority = 1 + lib.length preference - lib.lists.findFirstIndex (h: h == this-host) (lib.length preference) preference;
      };
    };

    systemd.services.patroni = let
      config-file = config.environment.sessionVariables.PATRONICTL_CONFIG_FILE;
    in {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # restarting the leader would fail over; a reload rereads the path
      # Patroni started with, so that is the stable /etc one
      reloadIfChanged = true;
      restartTriggers = [ config.environment.etc.${lib.removePrefix "/etc/" config-file}.source ];
      script = lib.mkForce ''
        replication="$(< ${config.site.secrets.postgresql-ha-replication.credentials.patroni})"
        export PATRONI_REPLICATION_PASSWORD="$replication" PATRONI_REWIND_PASSWORD="$replication"
        export PATRONI_RESTAPI_USERNAME=patroni PATRONI_RESTAPI_PASSWORD="$(< ${config.site.secrets.patroni-restapi.credentials.patroni})"
        exec ${lib.getExe pkgs.patroni} ${config-file}
      '';
      serviceConfig = {
        RuntimeDirectory = "postgresql-ha";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        MemorySwapMax = 0;
      };
    };

    systemd.targets.postgresql-ha-serving.description = "This host serves the apps beside the replicated Postgres";

    systemd.services.postgresql-ha-role = {
      description = "Follow where the replicated PostgreSQL leads and is served";
      wantedBy = [ "multi-user.target" ];
      after = [ "patroni.service" ];
      path = [ config.systemd.package pkgs.curl pkgs.jq pkgs.gawk ];
      # Serving stops only after 30 s of misses, outlasting blips and adoption
      script = ''
        # by /proc/locks: taking the lock, even briefly, can make a switch give up
        switching() {
          local inode
          inode=$(stat -c %i /run/nixos/switch-to-configuration.lock 2>/dev/null) || return 1
          awk -v inode="$inode" '$2 == "FLOCK" { n = split($6, id, ":"); if (id[n] == inode) held = 1 } END { exit !held }' /proc/locks
        }
        misses=0 streaming= since=0 fresh=1
        while :; do
          # Leave a switch's units to it, but for a first pass, which the trackers it starts wait on
          if [ -z "$fresh" ] && switching; then sleep 1; continue; fi
          cluster=$(curl -sf --max-time 3 ${patroni-api}/cluster) || cluster='{"members": []}'
          primary=$(jq -r '.members[] | select(.role == "leader") | .name' <<<"$cluster")
          # The leader serves if preferred, else the most preferred member still running
          serving=$(jq -r --arg leader "$primary" --argjson preference '${builtins.toJSON preference}' '
            if ($leader | IN($preference[])) then $leader
            else first($preference[] as $p | .members[] | select(.name == $p and (.state == "streaming" or .state == "running")) | .name) // "" end' <<<"$cluster")
          if [ -n "$primary" ]; then
            env=$(printf 'DB_PRIMARY=%s\nDB_SERVING=%s\nPGHOST=%s.internal\nPGPORT=%s' "$primary" "$serving" "$primary" ${toString ports.postgres.port})
            if [ "$env" != "$(cat ${primary-env} 2>/dev/null)" ]; then
              echo "$env" > ${primary-env}
              ${lib.optionalString (trackers != [ ]) "systemctl try-restart --no-block ${toString trackers}"}
            fi
          fi
          if [ -n "$primary" ] && [ "$serving" = ${this-host} ]; then
            misses=0
            systemctl start --no-block postgresql-ha-serving.target
          elif [ $((++misses)) -ge 6 ]; then
            systemctl stop --no-block postgresql-ha-serving.target
          fi
          ${lib.optionalString (ahead != [ ]) ''
            # Leading here: hand over to the first member preferred over this one once it has streamed for a while
            candidate=
            [ "$primary" != ${this-host} ] || candidate=$(jq -r --argjson ahead '${builtins.toJSON ahead}' '
              first($ahead[] as $p | .members[] | select(.name == $p and .state == "streaming") | .name) // ""' <<<"$cluster")
            [ "$candidate" = "$streaming" ] || { streaming=$candidate since=$SECONDS; }
            if [ -n "$candidate" ] && [ $((SECONDS - since)) -ge ${toString (config.site.ha.failback-minutes * 60)} ]; then
              echo "postgresql-ha: $candidate has streamed for ${toString config.site.ha.failback-minutes} minutes; handing over"
              printf 'user = "patroni:%s"\n' "$(< ${config.site.secrets.patroni-restapi.credentials.postgresql-ha-role})" |
              curl -sS --fail-with-body --max-time 60 -K - -H 'Content-Type: application/json' \
                -d "{\"leader\": \"${this-host}\", \"candidate\": \"$candidate\"}" ${patroni-api}/switchover ||
                echo "postgresql-ha: handing over to $candidate failed; retrying in ${toString config.site.ha.failback-minutes} minutes" >&2
              since=$SECONDS
            fi
          ''}
          systemd-notify --ready
          fresh=
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

    systemd.services.postgresql-ha-setup = lib.mkIf (lib.elem this-host preference) {
      description = "Roles and databases of the replicated PostgreSQL";
      wantedBy = [ "multi-user.target" ];
      wants = [ "postgresql-ha-role.service" "oidentd.service" ];
      after = [ "patroni.service" "postgresql-ha-role.service" "oidentd.service" ];
      script = "${package}/bin/psql -d postgres -f ${setup-sql}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        EnvironmentFile = primary-env;
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  } {
    systemd.sockets = lib.genAttrs cfg.follow-primary-sockets (_: {
      wantedBy = lib.mkForce [ "postgresql-ha-serving.target" ];
      partOf = [ "postgresql-ha-serving.target" ];
    });
    systemd.services = lib.genAttrs cfg.follow-primary (_: {
      # restarted after the reload: stopped before it, the role watcher
      # would start the old unit again before the switch could
      stopIfChanged = false;
      wantedBy = lib.mkForce [ "postgresql-ha-serving.target" ];
      partOf = [ "postgresql-ha-serving.target" ];
      requires = [ "postgresql-ha-setup.service" ];
      after = [ "postgresql-ha-setup.service" ];
      serviceConfig.ExecCondition = serves;
    });
  } {
    systemd.services = lib.genAttrs trackers (_: {
      wants = [ "postgresql-ha-role.service" "oidentd.service" "postgresql-ha-setup.service" ];
      after = [ "postgresql-ha-role.service" "oidentd.service" "postgresql-ha-setup.service" ];
    });
  } ]);
}
