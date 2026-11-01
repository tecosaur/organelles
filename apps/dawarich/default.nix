{ config, lib, pkgs, ... }:

let
  app = config.site.apps.dawarich;
in {
  site.apps.dawarich.enabled = true;

  services.dawarich = {
    enable = true;
    localDomain = app.domain;
    webPort = app.port;
    configureNginx = false;
    environment = {
      OIDC_CLIENT_ID = "dawarich";
      # OIDC_CLIENT_SECRET is set in the age secret file
      # Update when <https://github.com/NixOS/nixpkgs/issues/545545> is resolved
      OIDC_ISSUER = config.site.apps.authelia.url;
      OIDC_REDIRECT_URI = "${app.url}/users/auth/openid_connect/callback";
      OIDC_PKCE_ENABLED = "true";
      OIDC_PROVIDER_NAME = "Authelia";
      OIDC_AUTO_REGISTER = "true";
      ALLOW_EMAIL_PASSWORD_REGISTRATION = "false";
      ALLOW_EMAIL_PASSWORD_LOGIN = "false";
      PHOTON_API_HOST = "photon.koalasec.org";
      PHOTON_API_USE_HTTPS = "true";
      STORE_GEODATA = "true";
    };
    extraEnvFiles = [ app.auth.clients.dawarich.secret.decrypted ];
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    reverse_proxy :${toString app.port}
    '';
}
