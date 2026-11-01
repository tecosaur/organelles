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
    # beszel-agent is a core module, beside the hub or not
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
      clients.beszel.redirects = [ "api/oauth2-redirect" ];
    };
    secrets = {
      token = { kind = "credential"; description = "Beszel hub token"; };
    };
  };
  config.site.apps.beszel.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL6RP5omIbCzQsC/NizUg56JgpgMdl0/VXmCAE0VyJlq";
}
