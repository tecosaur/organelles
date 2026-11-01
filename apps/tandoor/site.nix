{ config, lib, site-lib, ... }:

{
  options.site.apps.tandoor = site-lib.mkAppOption {
    name = "Tandoor";
    homepage = "https://tandoor.dev";
    description = "recipe manager";
    service = "tandoor-recipes";
    subdomain = "recipes";
    port = 7203;
    auth = {
      policy.admins = "one_factor";
      clients.tandoor.redirects = [ "accounts/oidc/authelia/login/callback/" ];
    };
  };
  config.site.apps.tandoor.groups.extra = [ "family" ];
}
