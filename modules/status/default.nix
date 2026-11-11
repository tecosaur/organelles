{ config, lib, pkgs, ... }:

# The status page at status.<domain>: Gatus on the primary, fed
# entirely by gatus-aggregator from every host. Rows come from site.apps
# and from each host's site.status.units, which the modules running that
# infrastructure declare; what is declared here has no module of ours.

{
  imports = [ ./gatus.nix ./gatus-aggregator.nix ];

  site.status.units = [ {
    id = "system-units";
    name = "All system units";
    # Always active, so the check always runs; it catches what nothing else watches, such as a
    # oneshot or timer job failing
    unit = "multi-user.target";
    command = [ (lib.getExe (pkgs.writeShellApplication {
      name = "failed-units";
      runtimeInputs = [ config.systemd.package ];
      text = ''
        failed=$(systemctl --failed --plain --no-legend | cut -d' ' -f1 | paste -sd' ')
        [ -z "$failed" ] || { echo "$failed"; exit 1; }
      '';
    })) ];
  } ]
    ++ lib.optional config.services.caddy.enable { id = "caddy"; name = "Caddy"; unit = "caddy.service"; }
    ++ lib.optional config.services.postgresql.enable {
      id = "postgresql";
      name = "Local Postgres";
      unit = "postgresql.service";
      command = [ "${config.services.postgresql.package}/bin/pg_isready" "--quiet"
                  "--host=/run/postgresql" "--port=${toString config.services.postgresql.settings.port}"
                  "--dbname=postgres" ];
    };
}
