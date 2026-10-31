{ config, lib, ... }:

let
  app = config.site.apps.mail;
  inherit (config.site) domain;
  hostname = "${app.subdomain}.${domain}";
  credentials = "/run/credentials/bulwark.service";
  stalwart = "127.0.0.1:${toString app.port}";
  bulwark-port = app.ports.bulwark.port;
  # Next.js spells any loopback address localhost in a middleware rewrite, and proxies one not
  # at its own origin, which behind Caddy means to itself over https: so it listens as localhost
  bulwark = "localhost:${toString bulwark-port}";
  # Stalwart's HTTP routes in 1.0.3. Under /api, Bulwark has its own
  # /api/account/* and /api/auth/*, so of those only Stalwart's exact paths.
  stalwart-paths = [
    "/jmap" "/jmap/*"
    "/.well-known/jmap" "/.well-known/oauth-authorization-server" "/.well-known/oauth-protected-resource*"
    "/admin*" "/account*"
    "/api/account" "/api/auth" "/api/auth/client"
    "/api/calendar/*" "/api/discover/*" "/api/live/*" "/api/schema" "/api/schema/*" "/api/token/*"
  ];
  # Client autoconfiguration; Caddy matches paths case-insensitively, as Outlook needs
  autoconfig-paths = [
    "/.well-known/autoconfig/*" "/.well-known/mail-v1.xml" "/.well-known/user-agent-configuration.json"
    "/mail/config-v1.1.xml" "/autodiscover/*"
  ];
  to-stalwart = paths: ''
    @stalwart path ${toString paths}
    handle @stalwart {
        # This host's own calls, Bulwark's, stay here unforwarded: Stalwart refuses a forwarded loopback address
        @loopback remote_ip 127.0.0.0/8 ::1
        reverse_proxy @loopback ${stalwart} {
            flush_interval -1
            header_up -X-Forwarded-For
        }
        # The rest to the Stalwart beside the primary: one trip to it, rather than one per query
        ${config.site.ha.primary-proxy app.port}
    }
  '';
in {
  config = lib.mkIf config.site.ha.may-lead {
    age.secrets = {
      bulwark-oidc.file = ../../secrets/oidc/bulwark-secret.age;
      bulwark-session.file = ../../secrets/keys/bulwark-session.age;
    };
    services.bulwark = {
      enable = true;
      hostname = "localhost";
      port = bulwark-port;
      updateCheck.enabled = false;
      telemetry.enabled = false;
      settings = {
        jmapServerUrl = "https://${hostname}";
        oauth = {
          enabled = true;
          # Stalwart knows only Authelia's tokens and app passwords
          only = true;
          clientId = config.site.mail.oidc.bulwark-client;
          clientSecretFile = "${credentials}/oidc-secret";
          issuerUrl = config.site.mail.oidc.issuer;
          scopes = "openid profile ${config.site.mail.oidc.account-claim} offline_access";
        };
        # Shared by both hosts, so a sign-in survives a switch between them
        sessionSecretFile = "${credentials}/session-secret";
        # Its /admin is Stalwart's here
        stalwartAdminAccess = "off";
      };
    };
    systemd.services.bulwark.serviceConfig.LoadCredential = [
      "oidc-secret:${config.age.secrets.bulwark-oidc.path}"
      "session-secret:${config.age.secrets.bulwark-session.path}"
    ];
    # Bulwark's server-side JMAP calls then reach this host's Stalwart
    networking.hosts = {
      "127.0.0.1" = [ hostname ];
      "::1" = [ hostname ];
    };
    services.caddy.virtualHosts = {
      ${hostname}.extraConfig = ''
        # The site's icons in place of the apps' own, ahead of the routes to them: Stalwart's UIs ask
        # for favicon.ico beneath their own prefix, and Bulwark for the rest
        @stalwart-icon path /favicon.ico /admin/favicon.ico /account/favicon.ico
        handle @stalwart-icon {
            rewrite * /favicon.ico
            root * ${config.site.assets}/stalwart
            file_server
        }
        @bulwark-icons path /branding/Bulwark_Favicon.svg /branding/Bulwark_Logo_Color.svg /branding/Bulwark_Logo_White.svg /apple-touch-icon.png /icon-*.png
        handle @bulwark-icons {
            # Its logos too, light and dark, as the login and About pages show them
            rewrite /branding/* /favicon.svg
            root * ${config.site.assets}/bulwark
            file_server
        }
        ${to-stalwart (stalwart-paths ++ autoconfig-paths)}
        handle {
            reverse_proxy ${bulwark}
        }
      '';
    } // lib.genAttrs [ "autoconfig.${domain}" "autodiscover.${domain}" ] (_: {
      extraConfig = ''
        ${to-stalwart autoconfig-paths}
        handle {
            respond 404
        }
      '';
    });
  };
}
