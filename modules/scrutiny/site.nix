{ config, lib, site-lib, ... }:

{
  options.site.apps.scrutiny = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Scrutiny";
    homepage = "https://github.com/AnalogJ/scrutiny";
    description = "disk health monitoring";
    subdomain = "drives.health";
    port = 8606;
    ports.influxdb = { port = 8086; unit = "influxdb2"; clients = [ "scrutiny" ]; };
    clients = [ "scrutiny-collector" ];
  };
}
