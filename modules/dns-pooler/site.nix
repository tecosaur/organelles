{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  preference = config.site.databases.hosts;
  inherit (site-lib) mesh local;
in {
  config.site.reach.probes = [ "dns-pooler" ];
  config.site.ports = {
    dns-pooler-peer = mesh 9433 "dns-pooler" { dns-pooler = hosts; };
    dns-pooler-status = local 9434 "dns-pooler" { gatus-aggregator-report = hosts; gatus-aggregator-aggregate = preference; };
  };
  config.site.secrets = {
    bunny-dns-key = {
      kind = "credential";
      description = "Bunny API key, for dns-pooler; it also keys the peer channel, so every node needs the same one";
      units = { dns-pooler = config.site.hosts; caddy = config.site.hosts; };
    };
  };
}
