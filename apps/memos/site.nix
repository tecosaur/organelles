{ config, lib, site-lib, ... }:

{
  options.site.apps.memos = site-lib.mkAppOption {
    health.path = "/healthz";
    name = "Memos";
    homepage = "https://usememos.com";
    description = "quick notes";
    subdomain = "memos";
    port = 5230;
  };
  config.site.apps.memos.groups.extra = [ "family" ];
}
