{ config, lib, site-lib, ... }:

{
  options.site.apps.syncthing = site-lib.mkAppOption {
    health.path = "/rest/noauth/health";
    name = "Syncthing";
    homepage = "https://syncthing.net";
    description = "folder synchronisation";
    simpleicon = "syncthing";
    subdomain = "syncthing";
    port = 8384;
    clients = [ "syncthing-init" ];
  };
}
