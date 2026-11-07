{ config, lib, pkgs, ... }:

let
  relay-port = config.site.apps.headscale.ports.relay.port;
  tags = [ "sys-relay" ];
in {
  site.status.units = [ { id = "tailscale"; name = "Tailscale"; unit = "tailscaled.service"; } ];

  services.tailscale = {
    enable = true;
    port = config.site.ports.tailscale.port;
    openFirewall = false;
    useRoutingFeatures = "server";
    # key generated with: `headscale preauthkeys create -u 1 -e 99y --reusable --tags tag:sys-relay`
    authKeyFile = lib.mkIf config.site.apps.headscale.enabled config.site.secrets.tailscale-preauth.credential;
    extraUpFlags = [
      "--reset"
      "--accept-dns=false" # No need for MagicDNS
      "--advertise-exit-node"
      # "--ssh"
    ] ++ lib.optionals config.site.apps.headscale.enabled [
      "--login-server=${config.site.apps.headscale.url}"
      "--advertise-tags=${lib.concatMapStringsSep "," (tag: "tag:${tag}") tags}"
    ];
    extraSetFlags = [ "--relay-server-port=${toString relay-port}" ];
  };

  services.networkd-dispatcher = {
    enable = true;
    rules."50-tailscale" = {
      onState = ["routable"];
      script = let
        uplink = config.systemd.network.networks."10-uplink".matchConfig.Name;
      in ''[ "$IFACE" != ${uplink} ] || ${lib.getExe pkgs.ethtool} -K ${uplink} rx-udp-gro-forwarding on rx-gro-list off'';
    };
  };
}
