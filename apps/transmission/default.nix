{ config, lib, pkgs, ... }:

let
  app = config.site.apps.transmission;
  download-dir = "/data/media/downloads";
  incomplete-dir = "${download-dir}/.incomplete";
in {
  site.apps.transmission.enabled = true;
  services.transmission = {
    enable = true;
    group = "users";
    package = pkgs.transmission_4;
    openRPCPort = false;
    webHome = pkgs.flood-for-transmission;
    settings = {
      # RPC runs whatever torrent-done script it is told to, so only Caddy, behind Authelia, reaches it
      rpc-bind-address = "127.0.0.1";
      rpc-port = app.port;
      rpc-whitelist = "127.0.0.1,::1";
      rpc-host-whitelist = app.domain;
      rpc-authentication-required = false;
      ratio-limit-enabled = true;
      ratio-limit = 2;
      peer-port = app.ports.peer.port;
      inherit download-dir incomplete-dir;
      rename-partial-files = true;
      # applied by Transmission itself, over the unit's UMask
      umask = "002";
    };
  };
  systemd.services.transmission.serviceConfig.BindPaths = [ "/data/media" ];
  systemd.tmpfiles.rules = [
    "d ${download-dir} 0775 ${config.services.transmission.user} users - -"
    "d ${incomplete-dir} 0775 ${config.services.transmission.user} users - -"
  ];
  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    import auth
    reverse_proxy 127.0.0.1:${toString app.port}
    '';
}
