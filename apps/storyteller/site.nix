{ config, lib, site-lib, ... }:

{
  options.site.apps.storyteller = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Storyteller";
    homepage = "https://storyteller-platform.gitlab.io/storyteller/";
    description = "synced audiobook platform";
    subdomain = "books";
    port = 8001;
    # serves the whole filesystem, so for Storyteller alone
    ports.readium = { port = 8002; clients = [ "storyteller" ]; };
    cacheSubdirs = [ ".cache" ".local" "image-cache" ];
  };
  config.site.apps.storyteller.groups.extra = [ "family" ];
}
