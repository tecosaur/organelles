{ config, lib, pkgs, ... }:

let
  ntfy-domain = "${config.site.apps.ntfy.subdomain}.${config.site.domain}";
  ntfy-user = "ntfy";
in {
  site.apps.ntfy.enabled = true;

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${ntfy-domain}";
      listen-http = ":${toString config.site.apps.ntfy.port}";
      upstream-base-url = "https://ntfy.sh";
      behind-proxy = true;
      web-root = "/app";
      web-push-file = "${config.site.apps.ntfy.dir}/webpush.db";
      web-push-email-address = "services.ntfy@${config.site.domain}";
      auth-file = "${config.site.apps.ntfy.dir}/users.db";
      auth-default-access = "read-only";
      attachment-cache-dir = "${config.site.apps.ntfy.dir}/attachments";
      cache-file = "${config.site.apps.ntfy.dir}/cache.db";
    };
  };

  users.users."${ntfy-user}" = {
    isSystemUser = true;
    group = ntfy-user;
  };

  users.groups."${ntfy-user}" = {};

  systemd.services.ntfy-sh = {
    serviceConfig = {
      # Static user, so data-mounts binds the state directory and the
      # existing files keep their owner.
      DynamicUser = lib.mkForce false;
      User = ntfy-user;
      Group = ntfy-user;
      EnvironmentFile = config.site.apps.ntfy.secrets.webpush-keys-env.decrypted;
      StateDirectory = lib.mkForce "${baseNameOf config.site.apps.ntfy.dir}";
    };
  };

  services.caddy.virtualHosts."${ntfy-domain}".extraConfig =
    ''
    route /app {
        import auth
        reverse_proxy localhost:${toString config.site.apps.ntfy.port}
    }
    route * {
        reverse_proxy :${toString config.site.apps.ntfy.port}
    }
    '';
}
