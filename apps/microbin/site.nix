{ config, lib, site-lib, ... }:

{
  options.site.apps.microbin = site-lib.mkAppOption {
    health.path = "/";
    name = "Microbin";
    homepage = "https://github.com/szabodanika/microbin";
    description = "pastebin and url shortener";
    subdomain = "microbin";
    port = 4144;
    extraOptions = {
      title = lib.mkOption {
        type = lib.types.str;
        default = "Microbin";
        description = "Title of the Microbin app";
      };
      short-subdomain = lib.mkOption {
        type = lib.types.str;
        default = "bin";
        description = "Short subdomain for Microbin";
      };
    };
  };
  config.site.apps.microbin = {
    title = "μPaste";
    subdomain = "pastes";
    short-subdomain = "p";
    groups.primary = "paste";
  };
}
