{ config, lib, pkgs, ... }:

let
  app = config.site.apps.ntfy;
  ntfy-user = "ntfy";
in {
  site.apps.ntfy.enabled = true;

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = app.url;
      listen-http = "127.0.0.1:${toString app.port}";
      upstream-base-url = "https://ntfy.sh";
      behind-proxy = true;
      web-root = "/app";
      web-push-file = "${app.dir}/webpush.db";
      web-push-email-address = "services.ntfy@${config.site.domain}";
      auth-file = "${app.dir}/users.db";
      auth-default-access = "read-only";
      attachment-cache-dir = "${app.dir}/attachments";
      cache-file = "${app.dir}/cache.db";
    };
  };

  users.users.${ntfy-user} = {
    isSystemUser = true;
    group = ntfy-user;
  };

  users.groups.${ntfy-user} = {};

  systemd.services.ntfy-sh = {
    serviceConfig = {
      # Static user, so data-mounts binds the state directory and the
      # existing files keep their owner.
      DynamicUser = lib.mkForce false;
      User = ntfy-user;
      Group = ntfy-user;
      EnvironmentFile = app.secrets.webpush-keys-env.decrypted;
      StateDirectory = lib.mkForce "${baseNameOf app.dir}";
    };
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    route /app {
        import auth
        reverse_proxy 127.0.0.1:${toString app.port}
    }
    route * {
        reverse_proxy 127.0.0.1:${toString app.port}
    }
    '';
}
