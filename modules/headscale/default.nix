{ config, lib, pkgs, ... }:

let
  app = config.site.apps.headscale;
  headscale-port = app.port;
  headplane-port = app.ports.headplane.port;
  magicdns-domain = "${app.magicdns-subdomain}.${config.site.domain}";
in {
  site.apps.headscale.enabled = true;

  services.headscale = {
    enable = true;
    port = headscale-port;
    settings = {
      server_url = app.url;
      dns = {
        base_domain = magicdns-domain;
        override_local_dns = false;
      };
      oidc = {
        issuer = config.site.apps.authelia.url;
        client_id = "headscale";
        # a file, not a credential: its CLI and Headplane read this config too
        client_secret_path = app.auth.clients.headscale.secret.decrypted;
        scope = [ "openid" "profile" "email" "groups" ];
        allowed_groups = [ "headscale" ];
        pkce = {
          enabled = true;
          method = "S256";
        };
        extra_params = {
          domain_hint = config.site.domain;
        };
      };
      policy.mode = "database";
    };
  };

  # it exits when the discovery fetch fails
  systemd.services.headscale = {
    wants = [ "authelia-online.service" ];
    after = [ "authelia-online.service" ];
  };

  services.headplane = {
    enable = true;
    settings = {
      server = {
        host = "127.0.0.1";
        port = headplane-port;
        base_url = app.url;
        cookie_secret_path = "/var/lib/headplane/cookie_secret";
        cookie_secure = true;
        data_path = "/var/lib/headplane";
      };
      headscale = {
        url = app.url;
        api_key_path = "/var/lib/headplane/api_key";
      };
      integration = {
        agent = {
          enabled = true;
          host_name = "headplane-agent";
          work_dir = "/var/lib/headplane/agent";
        };
        proc.enabled = true;
      };
      oidc = {
        issuer = config.site.apps.authelia.url;
        client_id = "headplane";
        client_secret_path = app.auth.clients.headplane.secret.decrypted;
        disable_api_key_login = true;
        token_endpoint_auth_method = "client_secret_basic";
        use_pkce = true;
      };
    };
  };

  systemd.services.headplane.preStart = ''
    umask 077
    if [ ! -s /var/lib/headplane/cookie_secret ]; then
        head -c 32 /dev/urandom | base64 | head -c 32 > /var/lib/headplane/cookie_secret
    fi
    if [ ! -s /var/lib/headplane/api_key ]; then
        ${lib.getExe config.services.headscale.package} apikeys create -e 99y > /var/lib/headplane/api_key
    fi
  '';

  environment.systemPackages = [ config.services.headscale.package ];
  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    @ui path /admin /admin/*
    @browser-root {
        header User-Agent *Mozilla*
        path /
    }
    root ${config.site.assets}/headscale
    route {
        redir @browser-root /admin/
        handle /admin/favicon.ico {
             uri strip_prefix /admin
             file_server
        }
        reverse_proxy @ui :${toString headplane-port}
        file_server /favicon.ico
        reverse_proxy :${toString headscale-port}
    }
    '';
}
