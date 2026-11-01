{ config, lib, pkgs, ... }:

let
  memos-pkg = pkgs.memos;
  memos-port = toString config.site.apps.memos.port;
in {
  site.apps.memos.enabled = true;

  systemd.services.memos = {
    description = "memos";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${memos-pkg}/bin/memos --data /var/lib/memos --port ${memos-port} --instance-url ${config.site.apps.memos.url}";
      Restart = "always";
      RestartSec = 5;
      User = "memos";
      Group = "memos";
      StateDirectory = "memos";
      StandardOutput = "journal";
    };
  };

  users.users.memos = {
    isSystemUser = true;
    group = "memos";
  };

  users.groups.memos = { };

  services.caddy.virtualHosts.${config.site.apps.memos.domain}.extraConfig =
    ''
    @custom-assets {
        path /logo.webp
        path /full-logo.webp
    }
    handle @custom-assets {
        root ${config.site.assets}/memos
        file_server
    }
    reverse_proxy :${memos-port}
    '';
}
