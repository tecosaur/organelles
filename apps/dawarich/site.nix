{ config, lib, site-lib, ... }:

{
  options.site.apps.dawarich = site-lib.mkAppOption {
    health.path = "/api/v1/health";
    name = "Dawarich";
    homepage = "https://dawarich.com";
    description = "location timeline";
    service = "dawarich-web";
    subdomain = "timeline";
    port = 6805;
    auth = {
      policy = { };
      clients.dawarich = {
        redirects = [ "users/auth/openid_connect/callback" ];
        # sourced by its rails wrapper, as its user
        secret.owner = "dawarich";
      };
    };
  };
}
