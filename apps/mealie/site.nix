{ config, lib, site-lib, ... }:

{
  options.site.apps.mealie = site-lib.mkAppOption {
    health.path = "/api/app/about";
    name = "Mealie";
    homepage = "https://docs.mealie.io";
    description = "recipe manager";
    subdomain = "mealie";
    port = 9000;
    branding = {
      "/favicon.ico" = "mealie/favicon.ico";
      "/icons/*" = "mealie/";
    };
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
  config.site.apps.llm.secrets.api-key.units.mealie =
    lib.mkIf config.site.apps.llm.enabled config.site.apps.mealie.hosts;
}
