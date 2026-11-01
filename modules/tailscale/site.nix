{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.ports = {
    tailscale = public 41641 "tailscaled" // { protocols = [ "udp" ]; };
  };
  config.site.secrets = {
    tailscale-preauth = { kind = "credential"; description = "Tailscale pre-auth key"; };
  };
}
