{ config, lib, site-lib, ... }:

{
  options.site.apps.rustical = site-lib.mkAppOption {
    health.path = "/ping";
    name = "Rustical";
    homepage = "https://rustical.app";
    description = "calendar and contacts server";
    subdomain = "cal";
    port = 4811;
    auth = {
      policy = { };
      clients.rustical = {
        redirects = [ "frontend/login/oidc/callback" ];
        secret.units = [ "rustical" ];
      };
    };
  };
}
