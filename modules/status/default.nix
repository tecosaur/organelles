{ config, lib, pkgs, ... }:

# The status page at status.<domain>: Gatus on the HA primary, fed
# entirely by gatus-aggregator from every host. Rows come from site.apps
# and from each host's site.status.units, which the modules running that
# infrastructure declare; what is declared here has no module of ours.

{
  imports = [ ./gatus.nix ./gatus-aggregator.nix ];

  site.status.units =
    lib.optional config.services.caddy.enable { id = "caddy"; name = "Caddy"; unit = "caddy.service"; }
    ++ lib.optional config.services.postgresql.enable {
      id = "postgresql";
      name = "Local Postgres";
      unit = "postgresql.service";
      command = [ "${config.services.postgresql.package}/bin/pg_isready" "--quiet"
                  "--host=/run/postgresql" "--port=${toString config.services.postgresql.settings.port}"
                  "--dbname=postgres" ];
    };
}
