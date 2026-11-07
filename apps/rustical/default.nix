{ config, lib, pkgs, ... }:

let
  app = config.site.apps.rustical;
  rustical-start = pkgs.writeShellScript "rustical-start" ''
    export RUSTICAL_OIDC__CLIENT_SECRET="$(< ${app.auth.clients.rustical.secret.credential})"
    exec ${lib.getExe config.services.rustical.package} serve
  '';
in {
  site.apps.rustical.enabled = true;

  systemd.services.rustical.serviceConfig = {
    ExecStart = lib.mkForce rustical-start;
  };

  services.rustical = {
    enable = true;
    settings = {
      dav_push.enabled = true;
      frontend = {
        enabled = true;
        allow_password_login = false;
      };
      http.bind = "127.0.0.1:${toString app.port}";
      oidc = {
        name = "Authelia";
        issuer = config.site.apps.authelia.url;
        client_id = "rustical";
        claim_userid = "preferred_username";
        scopes = [ "openid" "profile" "email" "groups" ];
        # assign_memberships = {
        #   family = [ "group.family" ];
        # };
        allow_sign_up = true;
      };
    };
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    reverse_proxy 127.0.0.1:${toString app.port}
    '';
}
