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
      clients.vaultwarden.redirects = [ "identity/connect/oidc-signin" ];
    };
    secrets = {
      "rsa.pem" = { kind = "key"; generate = "rsa"; };
    };
  };
}
