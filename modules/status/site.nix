{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  preference = config.site.databases.hosts;
  inherit (site-lib) mesh;
in {
  config.site.reach.probes = [ "gatus-aggregator-report" ];
  config.site.databases.postgres.gatus.units.gatus = config.site.apps.gatus.hosts;
  options.site.apps.gatus = site-lib.mkAppOption {
    health = { path = "/health"; body = ''"status":"UP"''; };
    name = "Gatus";
    homepage = "https://gatus.io";
    description = "status page";
    followsPrimary = true;
    # its history lives in the shared Postgres
    usesStateDir = false;
    subdomain = "status";
    port = 3001;
    clients = { gatus-aggregator-report = hosts; gatus-aggregator-aggregate = preference; };
    secrets = let
      units = {
        gatus = config.site.apps.gatus.hosts;
        gatus-aggregator-report = hosts;
        gatus-aggregator-aggregate = preference;
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
