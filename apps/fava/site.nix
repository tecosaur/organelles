{ config, lib, site-lib, ... }:

{
  options.site.apps.fava = site-lib.mkAppOption {
    health = { path = "/"; status = 302; };
    name = "Fava";
    homepage = "https://beancount.github.io/fava/";
    description = "Beancount web interface";
    service = "fava";
    usesStateDir = false;
    subdomain = "fava";
    port = 5025;
  };
}
