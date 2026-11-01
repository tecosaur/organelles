{ config, lib, pkgs, ... }:

let
  app = config.site.apps.fava;
  bean-file = "${config.services.syncthing.dataDir}/tec-ledger/finance.beancount";
in {
  site.apps.fava.enabled = true;

  systemd.services.fava = {
    description = "Fava web interface for Beancount";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.fava}/bin/fava -H 127.0.0.1 -p ${toString app.port} ${bean-file}";
      Restart = "always";
      User = "fava";
      Group = "fava";
      StateDirectory = "fava";
      StandardOutput = "journal";
    };
  };

  users.users.fava = {
    isSystemUser = true;
    group = "fava";
    extraGroups = [ config.services.syncthing.user ];
  };

  users.groups.fava = { };

  services.caddy.virtualHosts.${app.domain}.extraConfig = ''
    import auth
    reverse_proxy 127.0.0.1:${toString app.port}
  '';
}
