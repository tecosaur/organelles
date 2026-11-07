{ config, lib, pkgs, ... }:

let
  app = config.site.apps.memos;
in {
  site.apps.memos.enabled = true;
  systemd.services.memos = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.memos} --data /var/lib/memos --addr 127.0.0.1 --port ${toString app.port} --instance-url ${app.url}";
      Restart = "always";
      RestartSec = 5;
      User = "memos";
      Group = "memos";
      StateDirectory = "memos";
    };
  };

  users.users.memos = {
    isSystemUser = true;
    group = "memos";
  };

  users.groups.memos = { };
}
