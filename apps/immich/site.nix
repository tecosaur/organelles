{ config, lib, site-lib, ... }:

{
  options.site.apps.immich = site-lib.mkAppOption {
    health.path = "/api/server/ping";
    name = "Immich";
    homepage = "https://immich.app";
    description = "photo and video management";
    simpleicon = "immich";
    service = "immich-server";
    usesStateDir = false;
    subdomain = "photos";
    port = 2283;
    ports.machine-learning = { port = 3003; unit = "immich-machine-learning"; clients = [ "immich-server" ]; };
  };
  config.site.apps.immich.groups.extra = [ "family" ];
}
