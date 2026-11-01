{ config, lib, site-lib, ... }:

{
  options.site.apps.memos = site-lib.mkAppOption {
    health.path = "/healthz";
    name = "Memos";
    homepage = "https://usememos.com";
    description = "quick notes";
    subdomain = "memos";
    port = 5230;
    auth = {
      policy = { };
      clients.memos = {
        redirects = [ "auth/callback" ];
        pkce = false;
        settings.token_endpoint_auth_method = "client_secret_post";
      };
    };
  };
  config.site.apps.memos.groups.extra = [ "family" ];
}
