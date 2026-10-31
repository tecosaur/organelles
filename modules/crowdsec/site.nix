{ config, lib, site-lib, ... }:

let
  inherit (site-lib) local;
in {
  config.site.ports = {
    crowdsec-api = local 8057 "crowdsec" [ "crowdsec-firewall-bouncer" "crowdsec-firewall-bouncer-register" ];
  };
}
