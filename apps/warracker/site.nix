{ config, lib, site-lib, ... }:

{
  options.site.apps.warracker = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Warracker";
    homepage = "https://warracker.com";
    description = "warranty tracking";
    subdomain = "warracker";
    port = 8087;
    auth = {
      policy = { };
      clients.warracker = {
        redirects = [ "api/oidc/callback" ];
        pkce = false;
      };
    };
    mail = { sender = "noreply"; units = [ "warracker" ]; };
  };
  config.site.apps.warracker.groups.extra = [ "family" ];
}
