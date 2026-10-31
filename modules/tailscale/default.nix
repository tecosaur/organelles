{ config, lib, pkgs, ... }:

let
  relay-port = config.site.apps.headscale.ports.relay.port;
  tags = [ "sys-relay" ];
in {
  site.status.units = [ { id = "tailscale"; name = "Tailscale"; unit = "tailscaled.service"; } ];

  age.secrets.tailscale-preauth = {
    owner = "root";
    group = "root";
    file = ../../secrets/credentials/tailscale-preauth.age;
  };

  services.tailscale = {
    enable = true;
    port = config.site.ports.tailscale.port;
    openFirewall = false;
    useRoutingFeatures = "server";
    # key generated with: `headscale preauthkeys create -u 1 -e 99y --reusable --tags tag:sys-relay`
    authKeyFile = lib.mkIf config.site.apps.headscale.enabled config.age.secrets.tailscale-preauth.path;
    extraUpFlags = [
      "--reset"
      "--accept-dns=false" # No need for MagicDNS
      "--advertise-exit-node"
      # "--ssh"
    ] ++ lib.optional config.site.apps.headscale.enabled
      "--login-server=https://${config.site.apps.headscale.subdomain}.${config.site.domain}";
    extraSetFlags = [ "--relay-server-port=${toString relay-port}" ];
  };

  services.networkd-dispatcher = {
    enable = true;
    rules."50-tailscale" = {
      onState = ["routable"];
      script = "${lib.getExe pkgs.ethtool} -K enp1s0 rx-udp-gro-forwarding on rx-gro-list off";
    };
  };
}
