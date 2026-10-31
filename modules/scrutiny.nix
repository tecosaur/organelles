{ config, lib, pkgs, ... }:

{
  site.apps.scrutiny.enabled = true;

  services.scrutiny = {
    enable = true;
    settings = {
      web.listen.port = config.site.apps.scrutiny.port;
      # notify.urls = [ "ntfy://${config.site.apps.ntfy.subdomain}" ];
    };
  };

  services.caddy.virtualHosts."${config.site.apps.scrutiny.subdomain}.${config.site.domain}".extraConfig =
    ''
    import auth
    reverse_proxy :${toString config.site.apps.scrutiny.port}
    '';
}
