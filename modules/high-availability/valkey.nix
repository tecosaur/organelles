{ config, lib, pkgs, ... }:

# Valkey and Sentinel ask who is master as they start, so a restart never
# brings a stale master back.

let
  cfg = config.services.ha.valkey;
  inherit (config.site.ha) primary members preference voters;
  inherit (config.site) ports;
  this-host = config.site.server.host;
  package = pkgs.valkey;
  address = host: config.site.mesh.addresses.${host};
  quorum = lib.length voters / 2 + 1;
  # replica-priority: lower is promoted first, 0 never, and 1 marks the Postgres leader
  priority = host: if lib.elem host preference
    then 100 + lib.lists.findFirstIndex (h: h == host) 0 preference
    else 0;
  # Prints "<address> <port>" of the master: the Sentinels' answer, else a
  # member already acting as one, else the preferred primary
  current-master = pkgs.writeShellScript "valkey-ha-master" ''
    ask() { ${package}/bin/valkey-cli -t 2 --raw -h "$1" -p "$2" "''${@:3}" 2>/dev/null; }
    for host in ${toString (map address voters)}; do
      master=$(ask "$host" ${toString ports.ha-sentinel.port} SENTINEL get-master-addr-by-name ha | paste -sd' ')
      [ -n "$master" ] && { echo "$master"; exit; }
    done
    for host in ${toString (map address (lib.unique (preference ++ members)))}; do
      [ "$(ask "$host" ${toString ports.ha-valkey.port} ROLE | head -1)" = master ] && { echo "$host ${toString ports.ha-valkey.port}"; exit; }
    done
    echo "${address primary} ${toString ports.ha-valkey.port}"
  '';
  valkey-conf = pkgs.writeText "valkey-ha.conf" ''
    bind ${address this-host} 127.0.0.1
    port ${toString ports.ha-valkey.port}
    dir /var/lib/valkey-ha
    appendonly yes
    replica-announce-ip ${address this-host}
    replica-priority ${toString (priority this-host)}
    min-replicas-to-write 1
    min-replicas-max-lag 10
  '';
  # Passwords are read from credentials at start, so none reaches the store
  user-lines = lib.concatStringsSep "\n  " (lib.mapAttrsToList (name: user:
    "printf 'user %s on >%s %s\\n' ${name} \"$(< \"$CREDENTIALS_DIRECTORY/valkey-${name}\")\" "
    + lib.escapeShellArg "${user.keys} ${user.channels} ${user.commands}") cfg.users);
  service = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-networkd.service" ];
    serviceConfig = {
      User = "valkey-ha";
      Group = "valkey-ha";
      Restart = "always";
      MemorySwapMax = 0;
    };
  };
in {
  options.services.ha.valkey.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        keys = lib.mkOption {
          type = lib.types.str;
          example = "~app:*";
          description = "ACL key patterns";
        };
        channels = lib.mkOption {
          type = lib.types.str;
          default = "resetchannels";
          example = "&app.events";
          description = "ACL Pub/Sub channel patterns";
        };
        commands = lib.mkOption {
          type = lib.types.str;
          example = "+@read +@write";
          description = "ACL command rules";
        };
      };
    });
    default = { };
    description = ''
      Valkey users beside the default one, each with a password from
      `keys/valkey-<name>.age`.
    '';
  };
  config = lib.mkIf (primary != null) (lib.mkMerge [
    {
      services.ha.valkey.users = {
        stalwart = {
          keys = "~*";
          channels = "&stwt.agora";
          commands = "+@all -@dangerous +eval +evalsha +scan +info +role";
        };
        s3-overflow = {
          keys = "~s3o:*";
          commands = "+@read +@write +@scripting +@connection -@dangerous +time +wait +role";
        };
      };
    }
    (lib.mkIf (lib.elem this-host (members ++ voters)) {
      environment.systemPackages = [ package ];
      users.users.valkey-ha = {
        isSystemUser = true;
        group = "valkey-ha";
      };
      users.groups.valkey-ha = { };
    })
    (lib.mkIf (lib.elem this-host members) {
      systemd.services.valkey-ha = lib.recursiveUpdate service {
        description = "Replicated Valkey";
        script = ''
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/${config.site.secrets.valkey-ha.credential-name}")"
          read -r master port < <(${current-master})
          {
            echo 'include "${valkey-conf}"'
            echo "requirepass $VALKEYCLI_AUTH"
            echo "masterauth $VALKEYCLI_AUTH"
            ${user-lines}
            [ "$master" = ${address this-host} ] || echo "replicaof $master $port"
          } > "$RUNTIME_DIRECTORY/valkey.conf"
          exec ${package}/bin/valkey-server "$RUNTIME_DIRECTORY/valkey.conf"
        '';
        serviceConfig = {
          RuntimeDirectory = "valkey-ha";
          RuntimeDirectoryMode = "0700";
          StateDirectory = "valkey-ha";
          StateDirectoryMode = "0700";
        };
      };
      site.status.units = [ { id = "valkey-ha"; name = "Replicated Valkey"; unit = "valkey-ha.service"; } ];
    })
    (lib.mkIf (lib.elem this-host preference) {
      systemd.services.valkey-ha-follow = lib.recursiveUpdate service {
        description = "Keep the Valkey master with the serving host";
        after = [ "valkey-ha.service" "postgresql-ha-role.service" ];
        path = [ package ];
        script = ''
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/${config.site.secrets.valkey-ha.credential-name}")"
          cli() { valkey-cli -t 2 --raw "$@" 2>/dev/null; }
          sentinel() {
            for host in ${toString (map address voters)}; do
              cli -h "$host" -p ${toString ports.ha-sentinel.port} SENTINEL "$@" && return
            done
          }
          stray=0
          while :; do
            # absent until Patroni has a leader
            serving=$(sed -n 's/^HA_SERVING=//p' ${config.services.ha.postgres.primary-env} 2>/dev/null) || serving=
            if [ "$serving" = ${this-host} ]; then want=1; else want=${toString (priority this-host)}; fi
            [ "$(cli -p ${toString ports.ha-valkey.port} CONFIG GET replica-priority | tail -1)" = "$want" ] ||
              cli -p ${toString ports.ha-valkey.port} CONFIG SET replica-priority "$want" >/dev/null || true
            master=$(sentinel get-master-addr-by-name ha | head -1)
            if [ "$serving" = ${this-host} ] && [ -n "$master" ] && [ "$master" != ${address this-host} ]; then
              if [ $((++stray)) -ge 6 ]; then
                echo "This host serves but the Valkey master is $master; handing it over"
                sentinel failover ha coordinated || true
                stray=0
                sleep 60
              fi
            else
              stray=0
            fi
            sleep 5
          done
        '';
      };
    })
    (lib.mkIf (lib.elem this-host voters) {
      # Sentinel rewrites its configuration as it learns, so it is written
      # afresh at each start and the rest relearned from its peers
      systemd.services.valkey-ha-sentinel = lib.recursiveUpdate service {
        description = "Sentinel for the replicated Valkey";
        script = ''
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/${config.site.secrets.valkey-ha.credential-name}")"
          read -r master port < <(${current-master})
          cat > "$STATE_DIRECTORY/sentinel.conf" <<EOF
          bind ${address this-host} 127.0.0.1
          port ${toString ports.ha-sentinel.port}
          sentinel announce-ip ${address this-host}
          requirepass $VALKEYCLI_AUTH
          sentinel sentinel-pass $VALKEYCLI_AUTH
          sentinel monitor ha $master $port ${toString quorum}
          sentinel auth-pass ha $VALKEYCLI_AUTH
          sentinel down-after-milliseconds ha 30000
          sentinel failover-timeout ha 180000
          sentinel parallel-syncs ha 1
          EOF
          exec ${package}/bin/valkey-sentinel "$STATE_DIRECTORY/sentinel.conf"
        '';
        serviceConfig = {
          StateDirectory = "valkey-ha-sentinel";
          StateDirectoryMode = "0700";
        };
      };
      site.status.units = [ { id = "valkey-ha-sentinel"; name = "Valkey Sentinel"; unit = "valkey-ha-sentinel.service"; } ];
    })
  ]);
}
