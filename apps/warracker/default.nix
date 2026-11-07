{ config, lib, pkgs, ... }:

let
  app = config.site.apps.warracker;
  warracker-user = "warracker";
  warracker-pkg = pkgs.callPackage ./package.nix {  };
  warracker-config = {
    registration_enabled = false;
    email_base_url = app.url;
    oidc_enabled = true;
    oidc_only_mode = true;
    oidc_skip_login_screen = true;
    oidc_client_id = "warracker";
    oidc_provider_name = "authelia";
    oidc_issuer_url = config.site.apps.authelia.url;
    oidc_scope = "openid email profile groups";
    oidc_admin_group = "admin";
  };
in {
  site.apps.warracker.enabled = true;

  systemd.services.warracker = {
    description = "Warracker Flask App";
    after = [ "network-online.target" "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      FLASK_ENV = "production";
      LOG_LEVEL = "info";
      BIND_ADDR = "127.0.0.1";
      PORT = toString app.port;
      FRONTEND_URL = app.url;
      APP_BASE_URL = app.url;
      GUNICORN_WORKERS = "2";
      DB_HOST = "/run/postgresql";
      DB_NAME = warracker-user;
      DB_USER = warracker-user;
      DB_PASSWORD = "";
      UPLOAD_FOLDER = "${app.dir}/uploads";
      WARRACKER_FIXED_CONFIG = (pkgs.formats.json {}).generate "warracker.json" warracker-config;
      OIDC_CLIENT_SECRET_FILE = app.auth.clients.warracker.secret.credential;
      SMTP_HOST = config.site.mail.connections.warracker.host;
      SMTP_PORT = toString config.site.mail.connections.warracker.port;
      SMTP_USE_TLS = "false";
      SMTP_FROM_ADDRESS = "Warracker (${config.site.domain}) <${config.site.mail.connections.warracker.from}>";
    };
    serviceConfig = {
      User = warracker-user;
      Group = "users";
      WorkingDirectory = app.dir;
      ExecStartPre = "${warracker-pkg}/bin/warracker-migrate";
      ExecStart = "${warracker-pkg}/bin/warracker-gunicorn";
      Restart = "on-failure";
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ warracker-user ];
    ensureUsers = [{
      name = warracker-user;
      ensureDBOwnership = true;
    }];
  };

  users.users.${warracker-user} = {
    isSystemUser = true;
    home = app.dir;
    createHome = true;
    group = warracker-user;
    extraGroups = [ "users" ];
  };

  users.groups.${warracker-user} = { };

  services.caddy.virtualHosts.${app.domain}.extraConfig = ''
    reverse_proxy /api/* :${toString app.port}
    file_server /favicon* {
      root ${config.site.assets}/warracker
    }
    file_server {
      root ${warracker-pkg}/share/warracker/static
      index index.html
    }
  '';
}
