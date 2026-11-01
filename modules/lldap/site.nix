{ config, lib, site-lib, ... }:

{
  options.site.apps.lldap = site-lib.mkAppOption {
    health.path = "/health";
    name = "LLDAP";
    homepage = "https://github.com/lldap/lldap";
    description = "user account management";
    followsPrimary = true;
    subdomain = "users";
    port = 17170;
    ports.ldap = {
      port = 3890;
      exposure = "mesh";
      # lldap checks it listens; Syncthing signs its GUI in
      clients = { authelia-main = config.site.apps.authelia.hosts; lldap = config.site.apps.lldap.hosts; syncthing = config.site.apps.syncthing.hosts; };
    };
    secrets = {
      jwt = { kind = "key"; generate = "rand"; };
      key-seed = { kind = "key"; generate = "rand"; };
      admin-password = { kind = "password"; description = "LLDAP admin login, used at its web UI"; };
    };
  };
}
