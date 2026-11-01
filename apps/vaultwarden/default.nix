{ config, lib, pkgs, ... }:

# Beside the HA primary alone, so a Login With Device approval
# and the WebSocket awaiting it meet in one process. Attachments and Sends
# stay on whichever host received them.

let
  app = config.site.apps.vaultwarden;
  vault-domain = "${app.subdomain}.${config.site.domain}";
in {
  config = lib.mkIf config.site.ha.may-lead {
    site.apps.vaultwarden.enabled = true;

    services.ha.postgres.databases = [ "vaultwarden" ];

    services.vaultwarden = {
      enable = true;
      dbBackend = "postgresql";
      config = {
        DOMAIN = "https://${vault-domain}";
        # The primary, by PGHOST and PGPORT; ident authenticates the system user as the role
        DATABASE_URL = "postgresql://vaultwarden@/vaultwarden";
        ROCKET_ADDRESS = "::";
        ROCKET_PORT = app.port;
        # .pem is appended; differing between members, it would sign
        # everyone out at each failover
        RSA_KEY_FILENAME = lib.removeSuffix ".pem" app.secrets."rsa_key.pem".credential;
        SIGNUPS_ALLOWED = false;
        # Authelia guards the admin page instead
        DISABLE_ADMIN_TOKEN = true;
        IP_HEADER = "X-Forwarded-For";
        TEMPLATES_FOLDER = toString (pkgs.writeTextDir "scss/user.vaultwarden.scss.hbs"
          (import ./theme.nix { inherit (config.site) accent; }));
        SSO_ENABLED = true;
        # the master password still signs in: the way back if Authelia is down
        SSO_ONLY = false;
        SSO_AUTHORITY = "https://${config.site.apps.authelia.subdomain}.${config.site.domain}";
        SSO_CLIENT_ID = "vaultwarden";
        SSO_CLIENT_SECRET_FILE = app.auth.clients.vaultwarden.secret.credential;
        # no refresh token, so no consent page, and sessions outlast Authelia
        SSO_AUTH_ONLY_NOT_SESSION = true;
        SMTP_HOST = config.site.mail.connections.vaultwarden.host;
        SMTP_PORT = config.site.mail.connections.vaultwarden.port;
        SMTP_SECURITY = "off";
        SMTP_FROM = config.site.mail.connections.vaultwarden.from;
        SMTP_FROM_NAME = "Vaultwarden on ${config.site.domain}";
      };
    };

    services.authelia.instances.main.settings.access_control.rules = [
      {
        domain = vault-domain;
        policy = "two_factor";
        subject = [ "group:${app.groups.admin}" ];
      }
      {
        domain = vault-domain;
        policy = "deny";
      }
    ];

    services.caddy.virtualHosts.${vault-domain}.extraConfig = ''
      @icons path /favicon.ico /images/favicon-* /images/apple-touch-icon.png /images/android-chrome-*
      handle @icons {
          root * ${config.site.assets}/vaultwarden
          file_server
      }
      route /admin* {
          import auth
          ${config.site.ha.primary-proxy app.port}
      }
      ${config.site.ha.primary-proxy app.port}
    '';
  };
}
