{ config, lib, site-lib, ... }:

{
  imports = [ ./online.nix ];
  options.site.apps.authelia = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Authelia";
    homepage = "https://www.authelia.com";
    description = "authentication and SSO portal";
    simpleicon = "authelia";
    # Named for its status checks; it keeps no state of its own
    service = "authelia-main";
    usesStateDir = false;
    subdomain = "auth";
    port = 9091;
    # The API, beside the primary: a relay to the local instance, run where the databases are served
    ports.api = { port = 9093; unit = "authelia-api"; exposure = "mesh"; hosts = config.site.databases.hosts; clients.caddy = config.site.hosts; };
    clients.authelia-api = config.site.databases.hosts;
    secrets = {
      jwt = { kind = "key"; generate = "rand"; };
      oidc-hmac = { kind = "key"; generate = "rand"; };
      "oidc-issuer.pem" = { kind = "key"; generate = "rsa"; };
      session = { kind = "key"; generate = "rand"; };
      storage = { kind = "key"; generate = "rand"; };
    };
    mail = { sender = "noreply"; units = [ "authelia-main" ]; };
  };
  config.site = let hosts = config.site.apps.authelia.hosts; in {
    databases = {
      postgres.authelia = { units.authelia-main = hosts; local-commits = true; };
      # its sessions, as the default user
      valkey.default.units.authelia-main = hosts;
    };
    apps.lldap = {
      ports.ldap.clients.authelia-main = hosts;
      secrets.admin-password.units.authelia-main = hosts;
    };
  };
}
