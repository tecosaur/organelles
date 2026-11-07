{ config, lib, pkgs, ... }:

let
  app = config.site.apps.scrutiny;
  influxdb-port = app.ports.influxdb.port;
in {
  site.apps.scrutiny.enabled = true;
  services.influxdb2.settings.http-bind-address = "127.0.0.1:${toString influxdb-port}";

  services.scrutiny = {
    enable = true;
    settings = {
      web.listen.port = app.port;
      web.influxdb = { host = "127.0.0.1"; port = influxdb-port; };
      # notify.urls = [ "ntfy://${config.site.apps.ntfy.subdomain}" ];
    };
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig = "import auth";
}
