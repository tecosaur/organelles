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
  };
}
