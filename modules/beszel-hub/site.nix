{ config, lib, site-lib, ... }:

{
  options.site.apps.beszel = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Beszel";
    homepage = "https://beszel.dev";
    description = "System monitoring";
    service = "beszel-hub";
    subdomain = "systems";
    port = 8090;
    ports.agent = { port = 45876; unit = "beszel-agent"; hosts = config.site.hosts; };
    admin = null;
    extra-groups = [ "admin" ];
    extraOptions = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Public key of the Beszel hub";
      };
      extra-filesystems = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional filesystems the agent should monitor";
      };
    };
    auth = {
      policy = { };
      clients.beszel = {
        redirects = [ "api/oauth2-redirect" ];
        # entered in its web UI
        secret.hosts = [ ];
      };
    };
    secrets = {
      token = { kind = "credential"; description = "Beszel hub token"; units.beszel-agent = config.site.hosts; };
    };
  };
}
