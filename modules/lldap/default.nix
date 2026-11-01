{ config, lib, pkgs, ... }:

let
  lldap-user = "lldap";
  lldap-web-domain = "${config.site.apps.lldap.subdomain}.${config.site.domain}";
  lldap-base-dn = lib.strings.concatMapStringsSep "," (dc: "dc=" + dc) (lib.splitString "." config.site.domain);
in {
  site.apps.lldap.enabled = true;

  services.lldap = {
    enable = true;
    settings = {
      ldap_base_dn = lldap-base-dn;
      ldap_port = config.site.apps.lldap.ports.ldap.port;
      http_port = config.site.apps.lldap.port;
      ldap_user_dn = "admin";
      ldap_user_email = "lldap-admin@${config.site.domain}";
      ldap_user_pass_file = config.site.apps.lldap.secrets.admin-password.credentials.lldap;
      force_ldap_user_pass_reset = "always";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.site.apps.lldap.secrets.jwt.credential;
      LLDAP_KEY_SEED_FILE = config.site.apps.lldap.secrets.key-seed.credential;
    };
  };

  # beside the primary: a search is eight queries, but one LDAP request
  services.ha.postgres.databases = [ lldap-user ];

  # for Authelia on every node

  systemd.services.lldap = {
    # The primary, from primary-env: LLDAP's ORM needs a host in the URL, so PGHOST cannot supply it
    script = lib.mkBefore ''
      export LLDAP_DATABASE_URL="postgresql://${lldap-user}@$HA_PRIMARY.internal:${toString config.site.ports.ha-postgres.port}/${lldap-user}"
    '';
    serviceConfig = {
      # started before it listens, which Authelia's startup check would beat
      ExecStartPost = pkgs.writeShellScript "lldap-listening" ''
        until (: </dev/tcp/localhost/${toString config.services.lldap.settings.ldap_port}) 2>/dev/null; do sleep 0.5; done
      '';
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  users.users.${lldap-user} = {
    group = lldap-user;
    isSystemUser = true;
  };
  users.groups.${lldap-user} = {};

  services.caddy.virtualHosts.${lldap-web-domain}.extraConfig =
    config.site.ha.primary-proxy config.services.lldap.settings.http_port;
}
