{ config, lib, pkgs, ... }:

let
  app = config.site.apps.speedtest;
in {
  site.apps.speedtest.enabled = true;

  services.librespeed = {
    enable = true;
    frontend = {
      enable = true;
      pageTitle = "Speed Test";
      contactEmail = "speedtest@${config.site.domain}";
      servers = [{
        name = app.domain;
        server = app.url;
      }];
    };
    settings = {
      listen_port = app.port;
      enable_tls = false;
    };
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    import auth
    route {
      root ${config.services.librespeed.settings.assets_path}
      reverse_proxy /backend/* :${toString app.port} {
        header_up X-Real-IP {http.request.remote.host}
      }
      respond /servers.json <<JSON
         ${builtins.toJSON config.services.librespeed.frontend.servers}
         JSON 200
      file_server
    }
    '';
}
