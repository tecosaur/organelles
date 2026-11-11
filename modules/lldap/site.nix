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
    ports.ldap = { port = 3890; exposure = "mesh"; };
    secrets = {
      jwt = { kind = "key"; generate = "rand"; units = [ "lldap" ]; };
      key-seed = { kind = "key"; generate = "rand"; units = [ "lldap" ]; };
      admin-password = {
        kind = "password";
        description = "LLDAP admin login, used at its web UI";
        units.lldap = config.site.apps.lldap.hosts;
      };
    };
  };
  # beside the primary: a search is eight queries, but one LDAP request
  config.site.databases.postgres.lldap.units.lldap = config.site.apps.lldap.hosts;
}
