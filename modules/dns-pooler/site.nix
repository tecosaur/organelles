{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  inherit (config.site.ha) preference;
  inherit (site-lib) mesh local;
in {
  config.site.reach.probes = [ "dns-pooler" ];
  config.site.ports = {
    dns-pooler-peer = mesh 9433 "dns-pooler" { dns-pooler = hosts; };
    dns-pooler-status = local 9434 "dns-pooler" { gatus-aggregator-report = hosts; gatus-aggregator-aggregate = preference; };
  };
}
