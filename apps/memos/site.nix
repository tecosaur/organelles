{ config, lib, site-lib, ... }:

{
  options.site.apps.memos = site-lib.mkAppOption {
    health.path = "/healthz";
    name = "Memos";
    homepage = "https://usememos.com";
    guide = ./guide.html;
    description = "quick notes";
    subdomain = "memos";
    port = 5230;
    branding = {
      "/logo.webp" = "memos/logo.webp";
      "/full-logo.webp" = "memos/full-logo.webp";
    };
    auth = {
      policy = { };
      clients.memos = {
        redirects = [ "auth/callback" ];
        pkce = false;
        settings.token_endpoint_auth_method = "client_secret_post";
        # entered in its web UI
        secret.hosts = [ ];
      };
    };
  };
}
