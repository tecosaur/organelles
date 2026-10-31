{ config, lib, site-lib, ... }:

{
  options.site.apps.tandoor = site-lib.mkAppOption {
    name = "Tandoor";
    homepage = "https://tandoor.dev";
    description = "recipe manager";
    service = "tandoor-recipes";
    subdomain = "recipes";
    port = 7203;
  };
  config.site.apps.tandoor.groups.extra = [ "family" ];
}
