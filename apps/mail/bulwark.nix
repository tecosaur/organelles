{ config, lib, ... }:

let
  app = config.site.apps.mail;
  inherit (config.site) domain;
  hostname = app.domain;
  stalwart = config.site.upstream app;
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
        # Bulwark's own calls go unforwarded: Stalwart refuses a forwarded loopback address
        @loopback remote_ip 127.0.0.0/8 ::1
        reverse_proxy @loopback ${stalwart.to} {
            ${stalwart.balancing}
            flush_interval -1
            header_up -X-Forwarded-For
        }
        ${config.site.proxy app}
    }
  '';
in {
  config = lib.mkIf config.site.databases.may-serve {
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
          clientSecretFile = app.auth.clients.${config.site.mail.oidc.bulwark-client}.secret.credential;
          issuerUrl = config.site.mail.oidc.issuer;
          scopes = "openid profile ${config.site.mail.oidc.account-claim} offline_access";
        };
        # Shared by both hosts, so a sign-in survives a switch between them
        sessionSecretFile = app.secrets.bulwark-session.credential;
        # Its /admin is Stalwart's here
        stalwartAdminAccess = "off";
      };
    };
    # Bulwark's server-side JMAP calls then go through this host's Caddy
    networking.hosts = {
      "127.0.0.1" = [ hostname ];
      "::1" = [ hostname ];
    };
    services.caddy.virtualHosts = {
      ${hostname}.extraConfig = ''
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
