{ config, lib, site-lib, ... }:

{
  options.site.apps.ntfy = site-lib.mkAppOption {
    health = { path = "/v1/health"; body = ''"healthy":true''; };
    name = "Ntfy";
    homepage = "https://ntfy.sh";
    description = "push notifications";
    simpleicon = "ntfy";
    service = "ntfy-sh";
    subdomain = "ntfy";
    port = 2586;
    auth.access.policy = "two_factor";
    secrets = {
      webpush-keys-env = { kind = "credential"; description = "ntfy web push keys"; };
    };
  };
}
