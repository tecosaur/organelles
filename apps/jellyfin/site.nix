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
  };
  config.site.apps.jellyfin.groups.extra = [ "family" ];
}
