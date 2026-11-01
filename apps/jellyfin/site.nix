{ config, lib, site-lib, ... }:

{
  options.site.apps.jellyfin = site-lib.mkAppOption {
    health.path = "/health";
    name = "Jellyfin";
    homepage = "https://jellyfin.org";
    description = "media server";
    simpleicon = "jellyfin";
    subdomain = "media";
    port = 8096;
    clients = [ "multi-scrobbler" ];
    auth.clients.jellyfin = {
      redirects = [ "sso/OID/redirect/authelia" ];
      settings = { authorization_policy = "one_factor"; token_endpoint_auth_method = "client_secret_post"; };
    };
    secrets = {
      meilisearch = { kind = "key"; generate = "meilisearch"; file-name = "meilisearch-jellyfin"; };
    };
  };
}
