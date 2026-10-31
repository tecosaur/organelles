{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.ports = {
    tailscale = public 41641 "tailscaled" // { protocols = [ "udp" ]; };
  };
}
