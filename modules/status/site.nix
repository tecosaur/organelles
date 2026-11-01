{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  inherit (config.site.ha) preference;
  inherit (site-lib) mesh;
in {
  config.site.reach.probes = [ "gatus-aggregator-report" ];
  options.site.apps.gatus = site-lib.mkAppOption {
    health = { path = "/health"; body = ''"status":"UP"''; };
    name = "Gatus";
    homepage = "https://gatus.io";
    description = "status page";
    followsPrimary = true;
    # its history lives in the replicated Postgres instance
    usesStateDir = false;
    subdomain = "status";
    port = 3001;
    clients = { gatus-aggregator-report = config.site.hosts; gatus-aggregator-aggregate = config.site.ha.preference; };
    secrets = let
      units = {
        gatus = config.site.apps.gatus.hosts;
        gatus-aggregator-report = config.site.hosts;
        gatus-aggregator-aggregate = config.site.ha.preference;
      };
    in {
      push = { kind = "key"; generate = "rand"; inherit units; };
      alert-topic = { kind = "key"; generate = "rand"; file-name = "status-alert-topic"; inherit units; };
    };
  };
  config.site.ports = {
    status-conditions = mesh 9435 "gatus-aggregator-report" { gatus-aggregator-report = hosts; gatus-aggregator-aggregate = preference; };
    status-announcement = mesh 9436 "gatus-aggregator-aggregate" { caddy = preference; };
  };
}
