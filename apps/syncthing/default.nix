{ config, lib, pkgs, ... }:

let
  app = config.site.apps.syncthing;
  ldap-port = config.services.lldap.settings.ldap_port;
  domain = config.site.domain;
  public-domain = "public.${domain}";
  my-computers = [ "tranquillity" "demure" "ict1634" ];
in {
  site.apps.syncthing.enabled = true;

  services.syncthing = {
    enable = true;
    dataDir = app.dir;
    guiAddress = "localhost:${toString app.port}";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      gui = {
        authMode = "ldap";
      };
      # its address follows the serving host, set by syncthing-init's postStart
      ldap = {
        bindDN = "uid=%s,ou=people,${config.services.lldap.settings.ldap_base_dn}";
        transport = "nontls";
        searchBaseDN = "ou=people,${config.services.lldap.settings.ldap_base_dn}";
        searchFilter = "(|(memberof=cn=${app.groups.primary},ou=groups,${config.services.lldap.settings.ldap_base_dn})(memberof=cn=${app.groups.admin},ou=groups,${config.services.lldap.settings.ldap_base_dn}))";
      };
      devices = {
        "tranquillity" = { id = "VXWXMXK-MWENVPV-PV75JQH-45OP44F-QMPH645-JVWGJB2-C2GKHSV-QARV5A2"; };
        "demure"       = { id = "DLCN7FP-BMHTAG6-QZHYGPJ-74IALUD-NZII77W-K73SPGU-L7QNGIS-NO674AH"; };
        "phone"        = { id = "IMNPYY2-BZMILMV-PYUCUOS-UCO4WNJ-UBRW7EY-VESRBGA-XHTNZ6G-E34J5QC"; };
        "ict1634"      = { id = "EG33JRV-Y6DUTXW-CNLYOLZ-H5A6SLS-I6INZIS-VISOZK3-2JV62MV-24K45A7"; };
      };
      folders = {
        "Autocorrections" = {
          id = "tec-autocorrections";
          path = "~/tec-autocorrections";
          devices = my-computers;
          type = "receiveonly";
        };
        "Public" = {
          id = "tec-public";
          path = "~/public";
          devices = [ "tranquillity" "demure" "phone" ];
          type = "receiveonly";
        };
        "Zotero Storage" = {
          id = "tec-zotero-storage";
          path = "~/tec-zotero-storage";
          devices = my-computers;
          type = "receiveonly";
        };
        "Finances" = {
          id = "tec-ledger";
          path = "~/tec-ledger";
          devices = [ "tranquillity" ];
          type = "sendreceive";
        };
        "Fonts" = {
          id = "tec-fonts";
          path = "~/tec-fonts";
          devices = my-computers;
          type = "receiveonly";
        };
      };
    };
  };

  # LLDAP runs only where the replicated Postgres is served
  services.ha.postgres.track-primary = [ "syncthing-init" ];
  systemd.services.syncthing-init.postStart = ''
    # left active, so the role watcher's restart once a host serves sets it
    if [ -z "''${HA_SERVING:-}" ]; then
      echo "No host serves LLDAP yet; its address is set once one does"
      exit 0
    fi
    address="$HA_SERVING.internal:${toString ldap-port}"
    ${lib.getExe pkgs.jq} -n --arg address "$address" '{ $address }' |
      ${lib.getExe pkgs.curl} -sSf -H "@$RUNTIME_DIRECTORY/headers" -X PATCH -d @- \
        http://${config.services.syncthing.guiAddress}/rest/config/ldap
  '';
  users.users = (lib.mkIf config.services.caddy.enable {
    syncthing = {
        homeMode = "750";
    };
    caddy.extraGroups = [ config.services.syncthing.group ];
  });

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    reverse_proxy ${config.services.syncthing.guiAddress} {
        header_up Host {upstream_hostport}
    }
    '';
  services.caddy.virtualHosts.${public-domain}.extraConfig =
    ''
    root ${config.services.syncthing.dataDir}/public/.build
    file_server
    '';
}
