{ config, lib, site-lib, ... }:

{
  options.site.apps.jellyfin = site-lib.mkAppOption {
    health.path = "/health";
    name = "Jellyfin";
    homepage = "https://jellyfin.org";
    guide = ./guide.html;
    description = "media server";
    simpleicon = "jellyfin";
    subdomain = "media";
    port = 8096;
    clients = [ "multi-scrobbler" ];
    auth.clients.jellyfin = {
      redirects = [ "sso/OID/redirect/authelia" ];
      settings = { authorization_policy = "one_factor"; token_endpoint_auth_method = "client_secret_post"; };
      secret.units = [ "jellyfin" ];
    };
    secrets = {
      meilisearch = { kind = "key"; generate = "meilisearch"; file-name = "meilisearch-jellyfin"; units = [ "jellyfin" ]; };
    };
  };
  config.site = {
    ports.meilisearch.clients.jellyfin = config.site.apps.jellyfin.hosts;
    apps.multi-scrobbler.secrets.jellyfin.units.jellyfin =
      lib.mkIf config.site.apps.multi-scrobbler.enabled config.site.apps.jellyfin.hosts;
  };
}
