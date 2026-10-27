{ config, lib, pkgs, ... }:

# Valkey and Sentinel ask who is master as they start, so a restart never
# brings a stale master back.

let
  inherit (config.site.ha) primary members preference voters ports;
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
      master=$(ask "$host" ${toString ports.sentinel} SENTINEL get-master-addr-by-name ha | paste -sd' ')
      [ -n "$master" ] && { echo "$master"; exit; }
    done
    for host in ${toString (map address (lib.unique (preference ++ members)))}; do
      [ "$(ask "$host" ${toString ports.valkey} ROLE | head -1)" = master ] && { echo "$host ${toString ports.valkey}"; exit; }
    done
    echo "${address primary} ${toString ports.valkey}"
  '';
  valkey-conf = pkgs.writeText "valkey-ha.conf" ''
    bind ${address this-host} 127.0.0.1
    port ${toString ports.valkey}
    dir /var/lib/valkey-ha
    appendonly yes
    replica-announce-ip ${address this-host}
    replica-priority ${toString (priority this-host)}
    min-replicas-to-write 1
    min-replicas-max-lag 10
  '';
  service = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-networkd.service" ];
    serviceConfig = {
      User = "valkey-ha";
      Group = "valkey-ha";
      Restart = "always";
      LoadCredential = [ "password:${config.age.secrets.valkey-ha.path}" ];
      MemorySwapMax = 0;
    };
  };
in {
  config = lib.mkIf (primary != null) (lib.mkMerge [
    (lib.mkIf (lib.elem this-host (members ++ voters)) {
      age.secrets.valkey-ha.file = ../../secrets/keys/valkey-ha.age;
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
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/password")"
          read -r master port < <(${current-master})
          {
            echo 'include "${valkey-conf}"'
            echo "requirepass $VALKEYCLI_AUTH"
            echo "masterauth $VALKEYCLI_AUTH"
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
      networking.firewall.interfaces.wg0.allowedTCPPorts = [ ports.valkey ];
      site.status.units = [ { id = "valkey-ha"; name = "Replicated Valkey"; unit = "valkey-ha.service"; } ];
    })
    (lib.mkIf (lib.elem this-host preference) {
      systemd.services.valkey-ha-follow = lib.recursiveUpdate service {
        description = "Keep the Valkey master with the Postgres primary";
        after = [ "valkey-ha.service" "postgresql-ha-role.service" ];
        path = [ package ];
        script = ''
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/password")"
          cli() { valkey-cli -t 2 --raw "$@" 2>/dev/null; }
          sentinel() {
            for host in ${toString (map address voters)}; do
              cli -h "$host" -p ${toString ports.sentinel} SENTINEL "$@" && return
            done
          }
          stray=0
          while :; do
            primary=$(sed -n 's/^HA_PRIMARY=//p' ${config.services.ha.postgres.primary-env} 2>/dev/null)
            if [ "$primary" = ${this-host} ]; then want=1; else want=${toString (priority this-host)}; fi
            [ "$(cli -p ${toString ports.valkey} CONFIG GET replica-priority | tail -1)" = "$want" ] ||
              cli -p ${toString ports.valkey} CONFIG SET replica-priority "$want" >/dev/null || true
            master=$(sentinel get-master-addr-by-name ha | head -1)
            if [ "$primary" = ${this-host} ] && [ -n "$master" ] && [ "$master" != ${address this-host} ]; then
              if [ $((++stray)) -ge 6 ]; then
                echo "Postgres leads here but the Valkey master is $master; handing it over"
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
          export VALKEYCLI_AUTH="$(< "$CREDENTIALS_DIRECTORY/password")"
          read -r master port < <(${current-master})
          cat > "$STATE_DIRECTORY/sentinel.conf" <<EOF
          bind ${address this-host} 127.0.0.1
          port ${toString ports.sentinel}
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
      networking.firewall.interfaces.wg0.allowedTCPPorts = [ ports.sentinel ];
      site.status.units = [ { id = "valkey-ha-sentinel"; name = "Valkey Sentinel"; unit = "valkey-ha-sentinel.service"; } ];
    })
  ]);
}
