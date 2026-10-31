{ config, lib, pkgs, ... }:

# etcd on each voter, over the mesh, so without TLS

let
  inherit (config.site.ha) voters primary ports;
  this-host = config.site.server.host;
  address = host: "[${config.site.mesh.addresses.${host}}]";
  peer-url = host: "http://${address host}:${toString ports.etcd-peer}";
  client-url = host: "http://${address host}:${toString ports.etcd}";
  local-url = "http://127.0.0.1:${toString ports.etcd}";
in {
  config = lib.mkIf (primary != null && lib.elem this-host voters) {
    services.etcd = {
      enable = true;
      name = this-host;
      listenPeerUrls = [ (peer-url this-host) ];
      listenClientUrls = [ (client-url this-host) local-url ];
      advertiseClientUrls = [ (client-url this-host) ];
      initialCluster = map (host: "${host}=${peer-url host}") voters;
      initialClusterToken = "ha";
      extraConf = {
        HEARTBEAT_INTERVAL = "500";
        ELECTION_TIMEOUT = "5000";
        # A read waits on the leader, a WAN round trip away, so the default 100 ms warns on every one
        WARNING_APPLY_DURATION = "1s";
      };
    };

    systemd.services.etcd = {
      after = [ "systemd-networkd.service" ];
      serviceConfig = {
        # etcd is only ready with quorum, which a lone first voter lacks
        Type = lib.mkForce "exec";
        MemorySwapMax = 0;
        CPUWeight = 500;
      };
    };

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ ports.etcd ports.etcd-peer ];

    site.status.units = [ {
      id = "etcd";
      name = "etcd";
      unit = "etcd.service";
      command = [ "${config.services.etcd.package}/bin/etcdctl" "--endpoints=${local-url}" "endpoint" "health" ];
    } ];
  };
}
