{ config, lib, pkgs, ... }:

# gatus-aggregator: every host reports on its own apps and units and on
# others' from outside; beside Gatus, wherever the HA primary is, the
# aggregator derives the fleet view and sends alerts.

let
  status = import ./plan.nix { inherit config lib; };
  package = pkgs.callPackage ../../packages/gatus-aggregator.nix { };
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
    serviceConfig = {
      ExecStart = "${lib.getExe package} -plan ${plan-file} ${command}";
      Restart = "always";
      RestartSec = "5s";
      LoadCredential = [
        "push:${config.age.secrets.gatus-push.path}"
        "topic:${config.age.secrets.status-alert-topic.path}"
      ];
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      CapabilityBoundingSet = "";
      UMask = "0077";
    };
  };
in {
  age.secrets.gatus-push.file = ../../secrets/keys/gatus-push.age;
  # peers tell each other's boards of planned transitions over the mesh
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ status.conditions-port ]
    ++ lib.optional config.site.ha.may-lead status.announcement-port;
  age.secrets.status-alert-topic.file = ../../secrets/keys/status-alert-topic.age;

  systemd.services.gatus-aggregator-report = service "report" "Status reports to Gatus";
  services.ha.postgres.probe-roles = [ "gatus-aggregator-report" ];
  services.postgresql.ensureUsers = lib.mkIf config.services.postgresql.enable [ { name = "gatus-aggregator-report"; } ];

  services.ha.postgres.follow-primary = lib.mkIf config.site.ha.may-lead [ "gatus-aggregator-aggregate" ];

  systemd.services.gatus-aggregator-aggregate = lib.mkIf config.site.ha.may-lead (lib.recursiveUpdate
    (service "aggregate" "Status aggregation and alerts beside Gatus") {
      after = [ "network-online.target" "dns-pooler.service" "gatus.service" ];
      # where the page's announcement outlasts a restart
      serviceConfig.StateDirectory = "gatus-aggregator";
    });
}
