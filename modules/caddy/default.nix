{ config, lib, pkgs, ... }:

{
  services.caddy = {
      enable = true;
      package = pkgs.caddy.withPlugins {
        plugins = [
          "github.com/caddy-dns/bunny@v1.2.0"
          "github.com/tecosaur/caddy-fs-git@v0.0.0-20261101180219-0b62135bc0e2"
          "github.com/caddyserver/replace-response@v0.0.0-20250618171559-80962887e4c6"
          "github.com/mholt/caddy-l4@v0.1.2"
        ];
        hash = "sha256-ydmVJ4WzUo9e1IqP+D/wPMjKXJLb2e8yRxC5JCj0lG8=";
      };
      globalConfig =
        ''
        # The challenge check finds the zone's nameservers through these, not
        # the system resolver, whose cache can trail a nameserver change by
        # a day and wait on a provider no longer authoritative.
        cert_issuer acme {
            dns bunny {file.${config.site.secrets.bunny-dns-key.credentials.caddy}}
            resolvers 1.1.1.1 8.8.8.8
        }
        '';
      # A Caddy snippet that can be imported to enable Authelia in front of a service
      # Taken from https://www.authelia.com/integration/proxies/caddy/#subdomain
      extraConfig = if builtins.hasAttr "main" config.services.authelia.instances &&
                       config.services.authelia.instances.main.enable then ''
          (auth) {
              forward_auth :${toString config.site.apps.authelia.port} {
                  uri /api/authz/forward-auth
                  copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
              }
          }
        '' else ''
          (auth) {
              forward_auth ${config.site.apps.authelia.url} {
                  header_up Host  {upstream_hostport}
                  uri /api/authz/forward-auth?rd=${config.site.apps.authelia.url}
                  copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
              }
          }
        '';
      virtualHosts."*.${config.site.domain}" = lib.mkIf config.site.server.authoritative {
        extraConfig =
          ''
          respond "In the beginning, there was darkness." 404
          '';
      };
  };
}
