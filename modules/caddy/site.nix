{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.reach.proxies = [ "caddy" ];
  config.site.ports = {
    http = public 80 "caddy";
    https = public 443 "caddy" // { protocols = [ "tcp" "udp" ]; };
  };
}
