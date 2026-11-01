{ config, lib, site-lib, ... }:

{
  options.site.apps.headscale = site-lib.mkAppOption {
    health.path = "/health";
    name = "Headscale";
    homepage = "https://headscale.net";
    description = "mesh virtual private network";
    subdomain = "headscale";
    port = 8174;
    ports = {
      headplane = { port = 8175; unit = "headplane"; clients = [ "caddy" ]; };
      relay = { port = 40108; unit = "tailscaled"; hosts = config.site.hosts; exposure = "public"; protocols = [ "tcp" "udp" ]; };
    };
    admin = null;
    extraOptions = {
      magicdns-subdomain = lib.mkOption {
        type = lib.types.str;
        default = "on";
        description = "Subdomain to use in the base domain for MagicDNS.";
      };
    };
    auth = {
      policy = { };
      clients = {
        headscale = {
          redirects = [ "oidc/callback" ];
          secret.owner = "headscale";
        };
        headplane = {
          redirects = [ "admin/oidc/callback" ];
          secret.owner = "headscale";
        };
      };
    };
  };
}
