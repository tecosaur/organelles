{ config, lib, pkgs, ... }:

let
  authelia = config.site.apps.authelia;
  authelia-port = authelia.port;
  authelia-user = "authelia";
  inherit (config.site.ha) members voters;
  inherit (config.site) ports;
  this-host = config.site.server.host;
  sentinels = map (host: { host = "${host}.internal"; port = ports.ha-sentinel.port; })
    (lib.optional (lib.elem this-host voters) this-host ++ lib.remove this-host voters);
  # for the status page's anonymous probes; a path of / is the app itself
  health-rules = lib.concatMap (app: lib.optional (app.health != null && !lib.elem app.health.path [ null "/" ]) {
    inherit (app) domain;
    resources = [ "^${lib.escapeRegex app.health.path}$" ];
    policy = "bypass";
  }) (lib.filter (app: app.enabled) (lib.attrValues config.site.apps));
  assets-no-symlinks = pkgs.runCommand "authelia-assets" {} ''
    mkdir -p $out
    cp -rL ${config.site.assets}/authelia/* $out
  '';
in {
  imports = [ ./apps.nix ];

  site.apps.authelia.enabled = true;

  services.authelia.instances.main = {
    enable = true;
    user = authelia-user;
    group = authelia-user;
    # loaded as credentials by the authelia module itself
    secrets = let secrets = authelia.secrets; in {
      jwtSecretFile = secrets.jwt.decrypted;
      oidcHmacSecretFile = secrets.oidc-hmac.decrypted;
      oidcIssuerPrivateKeyFile = secrets."oidc-issuer.pem".decrypted;
      sessionSecretFile = secrets.session.decrypted;
      storageEncryptionKeyFile = secrets.storage.decrypted;
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
            authelia_url = authelia.url;
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
        address = "ldap://{{ env \"HA_SERVING\" }}.internal:${toString config.services.lldap.settings.ldap_port}";
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
      # Stalwart waits on Authelia
      notifier.disable_startup_check = true;
      notifier.smtp = let mail = config.site.mail.connections.authelia; in {
        address = "smtp://${mail.host}:${toString mail.port}";
        sender = "${config.site.domain} authentication <${mail.from}>";
        subject = "{title}";
        # over loopback to the local Stalwart's door
        disable_require_tls = true;
        disable_starttls = true;
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
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.site.apps.lldap.secrets.admin-password.credentials.authelia-main;
      AUTHELIA_SESSION_REDIS_PASSWORD_FILE = config.site.secrets.valkey-ha.credentials.authelia-main;
      AUTHELIA_SESSION_REDIS_HIGH_AVAILABILITY_SENTINEL_PASSWORD_FILE = config.site.secrets.valkey-ha.credentials.authelia-main;
      # passes over hosts that can't take writes
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
        until (: </dev/tcp/"$HA_SERVING".internal/${toString config.services.lldap.settings.ldap_port}) 2>/dev/null; do sleep 1; done
      '')
    ];
  };

  users.users.${authelia-user} = {
    group = authelia-user;
    isSystemUser = true;
  };
  users.groups.${authelia-user} = {};

  # only the API needs the primary; the page is the same from any instance
  services.caddy.virtualHosts.${authelia.domain}.extraConfig = ''
    handle /api/* {
      ${config.site.ha.primary-proxy authelia-port}
    }
    handle {
      reverse_proxy localhost:${toString authelia-port}
    }
  '';
}
