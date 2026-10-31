{ config, lib, site-lib, ... }:

{
  options.site.apps.mealie = site-lib.mkAppOption {
    health.path = "/api/app/about";
    name = "Mealie";
    homepage = "https://docs.mealie.io";
    description = "recipe manager";
    subdomain = "mealie";
    port = 9000;
  };
  config.site.apps.mealie.subdomain = "food";
}
