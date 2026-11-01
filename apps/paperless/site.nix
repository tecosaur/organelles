{ config, lib, site-lib, ... }:

{
  options.site.apps.paperless = site-lib.mkAppOption {
    health.path = "/accounts/login/";
    name = "Paperless";
    homepage = "https://paperless-ngx.readthedocs.io";
    guide = ./guide.html;
    description = "document management";
    simpleicon = "paperlessngx";
    service = "paperless-web";
    subdomain = "folio";
    port = 28981;
    ports = {
      tika = { port = 9998; unit = "tika"; clients = [ "paperless-task-queue" ]; };
      gotenberg = { port = 3000; unit = "gotenberg"; clients = [ "paperless-task-queue" ]; };
    };
    auth = {
      policy.users = "two_factor";
      clients.paperless.redirects = [ "accounts/oidc/authelia/login/callback/" ];
    };
    secrets = {
      admin-password = { kind = "password"; description = "Paperless admin login"; };
    };
  };
  # read as root as the system activates, outside any unit
  config.site.apps.llm.secrets.api-key.hosts =
    lib.mkIf config.site.apps.llm.enabled config.site.apps.paperless.hosts;
}
