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
    # its GUI refuses a Host other than its own address
    proxy = false;
    clients = [ "syncthing-init" ];
  };
  config.site.apps.lldap.ports.ldap.clients.syncthing = config.site.apps.syncthing.hosts;
}
