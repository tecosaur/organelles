{ config, lib, site-lib, ... }:

{
  options.site.apps.tandoor = site-lib.mkAppOption {
    name = "Tandoor";
    homepage = "https://tandoor.dev";
    guide = ./guide.html;
    description = "recipe manager";
    service = "tandoor-recipes";
    subdomain = "recipes";
    port = 7203;
    auth = {
      policy.admins = "one_factor";
      clients.tandoor = {
        redirects = [ "accounts/oidc/authelia/login/callback/" ];
        secret.units = [ "tandoor-recipes" ];
      };
    };
    secrets = {
      fdc-api-key = { kind = "credential"; description = "USDA FoodData Central API key"; units = [ "tandoor-recipes" ]; };
    };
  };
}
