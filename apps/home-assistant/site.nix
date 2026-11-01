{ config, lib, site-lib, ... }:

{
  options.site.apps.home-assistant = site-lib.mkAppOption {
    health.path = "/manifest.json";
    name = "Home Assistant";
    homepage = "https://www.home-assistant.io";
    description = "home automation";
    simpleicon = "homeassistant";
    subdomain = "homeassistant";
    port = 8123;
    stateSubdirs = [ "state" ".storage" "blueprints" ];
    secrets = {
      secrets = { kind = "credential"; description = "Home Assistant secrets.yaml"; owner = "hass"; };
    };
  };
}
