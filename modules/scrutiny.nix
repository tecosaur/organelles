{ config, lib, pkgs, ... }:

let
  influxdb-port = config.site.apps.scrutiny.ports.influxdb.port;
in {
  site.apps.scrutiny.enabled = true;
  services.influxdb2.settings.http-bind-address = "127.0.0.1:${toString influxdb-port}";

  services.scrutiny = {
    enable = true;
    settings = {
      web.listen.port = config.site.apps.scrutiny.port;
      web.influxdb = { host = "127.0.0.1"; port = influxdb-port; };
      # notify.urls = [ "ntfy://${config.site.apps.ntfy.subdomain}" ];
    };
  };

  services.caddy.virtualHosts."${config.site.apps.scrutiny.subdomain}.${config.site.domain}".extraConfig =
    ''
    import auth
    reverse_proxy :${toString config.site.apps.scrutiny.port}
    '';
}
