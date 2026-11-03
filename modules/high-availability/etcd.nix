{ config, lib, pkgs, ... }:

# etcd on each voter, over the mesh, so without TLS

let
  inherit (config.site.ha) voters primary;
  inherit (config.site) ports;
  this-host = config.site.server.host;
  address = host: "[${config.site.mesh.addresses.${host}}]";
  peer-url = host: "http://${address host}:${toString ports.etcd-peer.port}";
  client-url = host: "http://${address host}:${toString ports.etcd.port}";
  local-url = "http://127.0.0.1:${toString ports.etcd.port}";
  metrics-url = "http://127.0.0.1:${toString ports.etcd-metrics.port}";
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
        LISTEN_METRICS_URLS = metrics-url;
      };
    };

    systemd.services.etcd = {
      serviceConfig = {
        # etcd is only ready with quorum, which a lone first voter lacks
        Type = lib.mkForce "exec";
        MemorySwapMax = 0;
        CPUWeight = 500;
      };
    };

    site.status.units = [ {
      id = "etcd";
      name = "etcd";
      unit = "etcd.service";
      command = [ "${lib.getExe pkgs.curl}" "--silent" "--fail" "--max-time" "3" "${metrics-url}/health" ];
    } ];
  };
}
