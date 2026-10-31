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
  };
  config.site.apps.dawarich.groups = { primary = "timeline"; extra = [ "family" ]; };
}
