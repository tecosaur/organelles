{ config, lib, site-lib, ... }:

{
  options.site.apps.transmission = site-lib.mkAppOption {
    name = "Transmission";
    homepage = "https://transmissionbt.com";
    description = "torrent client";
    simpleicon = "transmission";
    subdomain = "torrent";
    port = 9092;
    exposure = "public";
    ports.peer = { port = 58193; exposure = "public"; };
    stateSubdirs = [ ".config/transmission-daemon" ];
  };
}
