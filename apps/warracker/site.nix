{ config, lib, site-lib, ... }:

{
  options.site.apps.warracker = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Warracker";
    homepage = "https://warracker.com";
    description = "warranty tracking";
    subdomain = "warracker";
    port = 8087;
  };
  config.site.apps.warracker.groups.extra = [ "family" ];
}
