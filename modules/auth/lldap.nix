{ config, lib, pkgs, ... }:

let
  lldap-user = "lldap";
  lldap-web-domain = "${config.site.apps.lldap.subdomain}.${config.site.domain}";
  lldap-base-dn = lib.strings.concatMapStringsSep "," (dc: "dc=" + dc) (lib.splitString "." config.site.domain);
in {
  site.apps.lldap.enabled = true;

  age.secrets = {
    lldap-jwt = {
      owner = lldap-user;
      group = "users";
      file = ../../secrets/keys/lldap-jwt.age;
    };
    lldap-key-seed = {
      owner = lldap-user;
      group = "users";
      file = ../../secrets/keys/lldap-key-seed.age;
    };
    lldap-admin-password = {
      owner = lldap-user;
      group = "users";
      file = ../../secrets/passwords/lldap-admin-password.age;
    };
  };

  services.lldap = {
    enable = true;
    settings = {
      ldap_base_dn = lldap-base-dn;
      ldap_user_dn = "admin";
      ldap_user_email = "lldap-admin@${config.site.domain}";
      ldap_user_pass_file = config.age.secrets.lldap-admin-password.path;
      force_ldap_user_pass_reset = "always";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.age.secrets.lldap-jwt.path;
      LLDAP_KEY_SEED_FILE = config.age.secrets.lldap-key-seed.path;
    };
  };

  # beside the primary: a search is eight queries, but one LDAP request
  services.ha.postgres.databases = [ lldap-user ];

  # for Authelia on every node
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ config.services.lldap.settings.ldap_port ];

  systemd.services.lldap = {
    # The primary, from primary-env: LLDAP's ORM needs a host in the URL, so PGHOST cannot supply it
    script = lib.mkBefore ''
      export LLDAP_DATABASE_URL="postgresql://${lldap-user}@$HA_PRIMARY.internal:${toString config.site.ha.ports.postgres}/${lldap-user}"
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
