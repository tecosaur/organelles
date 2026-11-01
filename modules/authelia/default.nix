{ config, lib, pkgs, ... }:

let
  auth-domain = "${config.site.apps.authelia.subdomain}.${config.site.domain}";
  authelia-port = config.site.apps.authelia.port;
  authelia-user = "authelia";
  inherit (config.site.ha) members voters;
  inherit (config.site) ports;
  this-host = config.site.server.host;
  sentinels = map (host: { host = "${host}.internal"; port = ports.ha-sentinel.port; })
    (lib.optional (lib.elem this-host voters) this-host ++ lib.remove this-host voters);
  # for the status page's anonymous probes; a path of / is the app itself
  health-rules = lib.concatMap (app: lib.optional (app.health != null && lib.elem app.health.path [ null "/" ] == false) {
    domain = "${app.subdomain}.${config.site.domain}";
    resources = [ "^${lib.escapeRegex app.health.path}$" ];
    policy = "bypass";
  }) (lib.filter (app: app.enabled) (lib.attrValues config.site.apps));
  assets-no-symlinks = pkgs.runCommand "autheleia-assets" {} ''
    mkdir -p $out
    cp -rL ${config.site.assets}/authelia/* $out
  '';
in {
  imports = [ ./apps.nix ];

  site.apps.authelia.enabled = true;

  age.secrets = {
    authelia-session = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/keys/authelia-session.age;
    };
    authelia-storage = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/keys/authelia-storage.age;
    };
    authelia-jwt = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/keys/authelia-jwt.age;
    };
    authelia-smtp = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/credentials/fastmail.age;
    };
    authelia-oidc-hmac = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/keys/authelia-oidc-hmac.age;
    };
    authelia-oidc-issuer-key = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/keys/authelia-oidc-issuer.pem.age;
    };
    authelia-lldap-admin-password = {
      owner = authelia-user;
      group = "users";
      file = ../../secrets/passwords/lldap-admin-password.age;
    };
    authelia-valkey = {
      owner = authelia-user;
      file = ../../secrets/keys/valkey-ha.age;
    };
  };

  services.authelia.instances.main = {
    enable = true;
    user = authelia-user;
    group = authelia-user;
    secrets =  {
      jwtSecretFile = config.age.secrets.authelia-jwt.path;
      oidcHmacSecretFile = config.age.secrets.authelia-oidc-hmac.path;
      oidcIssuerPrivateKeyFile = config.age.secrets.authelia-oidc-issuer-key.path;
      sessionSecretFile = config.age.secrets.authelia-session.path;
      storageEncryptionKeyFile = config.age.secrets.authelia-storage.path;
    };
    settings = {
      theme = "auto";
      server = {
        address = "tcp://:${toString authelia-port}";
        asset_path = assets-no-symlinks;
      };
      session = {
        cookies = [
          ({
            domain = config.site.domain;
            authelia_url = "https://${auth-domain}";
            default_redirection_url = "https://${config.site.domain}/reload";
          })
        ];
        redis = {
          inherit (lib.head sentinels) host port;
          high_availability = {
            sentinel_name = "ha";
            nodes = lib.tail sentinels;
            route_by_latency = true;
          };
        };
      };
      access_control = {
        default_policy = "deny";
        rules = lib.mkMerge [
          (lib.mkBefore health-rules)
          (lib.mkAfter [
            {
              domain = "*.${config.site.domain}";
              policy = "one_factor";
            }
          ])
        ];
      };
      password_policy.standard = {
        enabled = true;
        min_length = 12;
      };
      webauthn = {
        enable_passkey_login = true;
        experimental_enable_passkey_uv_two_factors = true;
        experimental_enable_passkey_upgrade = true;
        selection_criteria = {
          attachment = "platform";
          discoverability = "required";
          user_verification = "preferred";
        };
        attestation_conveyance_preference = "direct";
        filtering.prohibit_backup_eligibility = false;
        metadata = {
          enabled = true;
          cache_policy = "relaxed";
          validate_trust_anchor = true;
          validate_entry = false;
          validate_status = true;
          validate_entry_permit_zero_aaguid = false;
        };
      };
      authentication_backend.ldap = {
        address = "ldap://{{ env \"HA_PRIMARY\" }}.internal:${toString config.services.lldap.settings.ldap_port}";
        base_dn = config.services.lldap.settings.ldap_base_dn;
        users_filter = "(&({username_attribute}={input})(objectClass=person))";
        groups_filter = "(member={dn})";
        # From the base, the group filter would reach users too, whose missing member LLDAP warns of
        additional_groups_dn = "ou=groups";
        user = "uid=${config.services.lldap.settings.ldap_user_dn},ou=people,${config.services.lldap.settings.ldap_base_dn}";
      };
      # PGTARGETSESSIONATTRS passes over hosts that can't take writes
      storage.postgres = {
        address = "unix://${config.services.ha.postgres.socket-dir}/.s.PGSQL.${toString ports.ha-postgres.port}";
        servers = map (host: { address = "tcp://${host}.internal:${toString ports.ha-postgres.port}"; })
          (lib.remove this-host members);
        database = authelia-user;
        username = authelia-user;
      };
      notifier.smtp = {
        address = "${config.site.email.server}:${toString config.site.email.port}";
        username = config.site.email.username;
        sender = "${config.site.domain} authentication <services.authentication@${config.site.domain}>";
        subject = "{title}";
      };
      log.level = "debug";
      identity_providers.oidc = {
        cors = {
          endpoints = [ "authorization" "token" "revocation" "introspection" "userinfo" ];
          allowed_origins_from_client_redirect_uris = true;
        };
        authorization_policies.default = {
          default_policy = "one_factor";
          rules = [
            {
              policy = "deny";
              subject = "group:lldap_strict_readonly";
            }
          ];
        };
      };
      # Necessary for Caddy integration
      # See https://www.authelia.com/integration/proxies/caddy/#implementation
      server.endpoints.authz.forward-auth.implementation = "ForwardAuth";
    };
    environmentVariables = {
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.age.secrets.authelia-lldap-admin-password.path;
      AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE = config.age.secrets.authelia-smtp.path;
      AUTHELIA_SESSION_REDIS_PASSWORD_FILE = config.age.secrets.authelia-valkey.path;
      AUTHELIA_SESSION_REDIS_HIGH_AVAILABILITY_SENTINEL_PASSWORD_FILE = config.age.secrets.authelia-valkey.path;
      PGTARGETSESSIONATTRS = "read-write";
      X_AUTHELIA_CONFIG_FILTERS = "template";
    };
  };

  services.ha.postgres = {
    databases = [ authelia-user ];
    local-commits = [ authelia-user ];
    track-primary = [ "authelia-main" ];
  };

  systemd.services.authelia-main = {
    after = [ "lldap.service" ];
    # its LDAP check at startup is fatal, and LLDAP may still be starting
    serviceConfig.ExecStartPre = lib.mkBefore [
      (pkgs.writeShellScript "authelia-await-ldap" ''
        until (: </dev/tcp/"$HA_PRIMARY".internal/${toString config.services.lldap.settings.ldap_port}) 2>/dev/null; do sleep 1; done
      '')
    ];
  };

  users.users.${authelia-user} = {
    group = authelia-user;
    isSystemUser = true;
  };
  users.groups.${authelia-user} = {};

  # only the API needs the primary; the page is the same from any instance
  services.caddy.virtualHosts."${auth-domain}".extraConfig = ''
    handle /api/* {
      ${config.site.ha.primary-proxy authelia-port}
    }
    handle {
      reverse_proxy localhost:${toString authelia-port}
    }
  '';
}
