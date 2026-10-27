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
      database_url = with config; "postgresql://${lldap-user}@localhost:${toString site.ha.ports.postgres}/${lldap-user}?host=${services.ha.postgres.socket-dir}";
    };
    environment = {
      LLDAP_JWT_SECRET_FILE = config.age.secrets.lldap-jwt.path;
      LLDAP_KEY_SEED_FILE = config.age.secrets.lldap-key-seed.path;
    };
  };

  services.ha.postgres.databases.${lldap-user} = "lldap";

  # LLDAP counts as started before it listens, so Authelia's startup check could beat it
  systemd.services.lldap.serviceConfig.ExecStartPost = pkgs.writeShellScript "lldap-listening" ''
    until (: </dev/tcp/localhost/${toString config.services.lldap.settings.ldap_port}) 2>/dev/null; do sleep 0.5; done
  '';

  users.users.${lldap-user} = {
    group = lldap-user;
    isSystemUser = true;
  };
  users.groups.${lldap-user} = {};

  services.caddy.virtualHosts.${lldap-web-domain}.extraConfig = ''
    reverse_proxy localhost:${toString config.services.lldap.settings.http_port}
  '';
}
