{ config, lib, site-lib, ... }:

{
  options.site.apps.mealie = site-lib.mkAppOption {
    health.path = "/api/app/about";
    name = "Mealie";
    homepage = "https://docs.mealie.io";
    description = "recipe manager";
    subdomain = "mealie";
    port = 9000;
    auth.clients.mealie = {
      redirects = [ "login" "http://localhost:${toString config.site.apps.mealie.port}/login" ];
      settings.authorization_policy = "one_factor";
      # in mealie-credentials-env, with its SMTP password
      secret = null;
    };
    secrets = {
      credentials-env = { kind = "credential"; description = "Mealie OIDC/SMTP environment"; };
    };
  };
  config.site.apps.mealie.subdomain = "food";
}
