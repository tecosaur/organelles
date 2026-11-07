{ config, lib, pkgs, ... }:

let
  app = config.site.apps.beszel;
in {
  site.apps.beszel.enabled = true;

  services.beszel.hub = {
    enable = true;
    port = app.port;
    environment = {
      APP_URL = app.url;
      SHARE_ALL_SYSTEMS = "true";
      USER_CREATION = "true";
      USER_EMAIL = "admin@${config.site.domain}";
      USER_PASSWORD = "letmeinn";
      DISABLE_PASSWORD_AUTH = "true";
    };
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    handle /static/icon.svg {
        uri strip_prefix /static/
        root ${config.site.assets}/beszel-hub
        file_server
    }
    reverse_proxy :${toString app.port}
    '';
}
