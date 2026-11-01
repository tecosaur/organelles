{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.ports = {
    ssh = public 22 "sshd";
    mdns = public 5353 "systemd-resolved" // { protocols = [ "udp" ]; hosts = lib.mkDefault [ ]; };
  };
}
