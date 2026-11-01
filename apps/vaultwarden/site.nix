{ config, lib, site-lib, ... }:

{
  options.site.apps.vaultwarden = site-lib.mkAppOption {
    health.path = "/alive";
    name = "Vaultwarden";
    homepage = "https://github.com/dani-garcia/vaultwarden";
    description = "password manager";
    simpleicon = "vaultwarden";
    followsPrimary = true;
    stateSubdirs = [ "attachments" "sends" ];
    subdomain = "vault";
    port = 8222;
    auth = {
      policy.users = "two_factor";
      clients.vaultwarden = {
        redirects = [ "identity/connect/oidc-signin" ];
        secret.units = [ "vaultwarden" ];
      };
    };
    secrets = {
      # named as Vaultwarden looks for it, its path less .pem given
      "rsa_key.pem" = { kind = "key"; generate = "rsa"; file-name = "vaultwarden-rsa.pem"; units = [ "vaultwarden" ]; };
    };
    mail = { sender = "noreply"; units = [ "vaultwarden" ]; };
  };
  config.site.ports.ha-postgres.clients.vaultwarden = config.site.apps.vaultwarden.hosts;
}
