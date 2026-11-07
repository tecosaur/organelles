{ config, lib, pkgs, ... }:

# gatus-aggregator: every host reports on its own apps and units and on
# others' from outside; beside Gatus, wherever the HA primary is, the
# aggregator derives the fleet view and sends alerts.

let
  status = import ./plan.nix { inherit config lib; };
  package = pkgs.callPackage ./package.nix { };
  # a plan that fails validation fails the build, not the deploy
  plan-file = pkgs.runCommand "gatus-aggregator-plan.json" { nativeBuildInputs = [ package ]; } ''
    cp ${pkgs.writeText "plan.json" (builtins.toJSON status.plan)} $out
    gatus-aggregator -plan $out check
  '';
  service = command: description: {
    inherit description;
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "dns-pooler.service" ];
    # systemctl reads unit state for the reporter
    path = [ config.systemd.package ];
    sandboxed = true;
    serviceConfig = {
      ExecStart = "${lib.getExe package} -plan ${plan-file} ${command}";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };
in {
  systemd.services.gatus-aggregator-report = service "report" "Status reports to Gatus";
  services.ha.postgres.probe-roles = [ "gatus-aggregator-report" ];
  services.postgresql.ensureUsers = lib.mkIf config.services.postgresql.enable [ { name = "gatus-aggregator-report"; } ];

  services.ha.postgres.follow-primary = lib.mkIf config.site.ha.may-serve [ "gatus-aggregator-aggregate" ];

  systemd.services.gatus-aggregator-aggregate = lib.mkIf config.site.ha.may-serve (lib.recursiveUpdate
    (service "aggregate" "Status aggregation and alerts beside Gatus") {
      after = [ "network-online.target" "dns-pooler.service" "gatus.service" ];
      # where the page's announcement outlasts a restart
      serviceConfig.StateDirectory = "gatus-aggregator";
    });
}
