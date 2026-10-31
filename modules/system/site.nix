{ config, lib, site-lib, ... }:

let
  inherit (site-lib) public;
in {
  config.site.ports = {
    ssh = public 22 "sshd";
    # a host's own modules add it where it answers
    mdns = public 5353 "systemd-resolved" // { protocols = [ "udp" ]; hosts = lib.mkDefault [ ]; };
  };
}
