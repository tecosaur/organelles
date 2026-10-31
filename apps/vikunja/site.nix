{ config, lib, site-lib, ... }:

{
  options.site.apps.vikunja = site-lib.mkAppOption {
    name = "Vikunja";
    homepage = "https://vikunja.io/";
    description = "task and project management";
    subdomain = "tasks";
    port = 3456;
  };
}
