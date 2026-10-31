{ config, lib, site-lib, ... }:

{
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
    # the other hosts' Caddy proxy /api/* to it
    exposure = "mesh";
  };
}
