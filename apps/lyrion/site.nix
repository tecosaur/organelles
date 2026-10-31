{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.ports = {
    slimproto = public 3483 "slimserver" // { protocols = [ "tcp" "udp" ]; };
    lyrion-web = public 9000 "slimserver";
    lyrion-cli = public 9090 "slimserver";
  };
}
