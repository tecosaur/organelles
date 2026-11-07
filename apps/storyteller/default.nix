{ config, lib, pkgs, ... }:

let
  storyteller = config.site.apps.storyteller;
  storyteller-pkg = pkgs.callPackage ./package.nix { whisper = pkgs.whisper-cpp-vulkan; };
  storyteller-import = "/data/media/books";
  # optional: a user token from hardcover.app
  has-hardcover-token = builtins.pathExists storyteller.secrets.hardcover-token.file;
in {
  site.apps.storyteller.enabled = true;

  systemd.services.storyteller = {
    description = "Storyteller synced audiobook platform";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Readium process management utilities
    path = with pkgs; [ lsof procps ];
    environment = {
      NODE_ENV = "production";
      PORT = toString storyteller.port;
      HOSTNAME = "127.0.0.1";
      READIUM_PORT = toString storyteller.ports.readium.port;
      STORYTELLER_DATA_DIR = storyteller.dir;
      STORYTELLER_LOG_LEVEL = "info";
      STORYTELLER_SECRET_KEY_FILE = "${storyteller.dir}/secret_key";
      STORYTELLER_CONFIG = (pkgs.formats.json {}).generate "storyteller-config.json" ({
        libraryName = "Books @ ${config.site.domain}";
        webUrl = storyteller.url;
        preferenceDefaults.accentColor = config.site.accent.primary;
        importMode = "copy";
        epub2ImportStrategy = "replace";
        importRules = [
          {
            kind = "watch";
            path = storyteller-import;
          }
        ];
        authProviders = [{
          kind = "custom";
          name = "Authelia";
          issuer = config.site.apps.authelia.url;
          clientId = "storyteller";
          clientSecret_file = storyteller.auth.clients.storyteller.secret.credential;
          type = "oidc";
          allowRegistration = true;
          groupPermissions = {
            "${storyteller.groups.admin}" = [
              "bookCreate" "bookRead" "bookProcess" "bookDownload" "bookList"
              "bookDelete" "bookUpdate" "collectionCreate" "inviteList"
              "inviteDelete" "userCreate" "userList" "userRead" "userDelete"
              "userUpdate" "settingsUpdate"];
          } // lib.mergeAttrsList (lib.map (g: { "${g}" = [ "bookRead" "bookDownload" "bookList" "bookCreate" ]; })
            ([ storyteller.groups.primary ] ++ storyteller.groups.extra));
        }];
        disablePasswordLogin = true;
        smtpHost = config.site.mail.connections.storyteller.host;
        smtpPort = config.site.mail.connections.storyteller.port;
        smtpFrom = "Storyteller (${config.site.domain}) <${config.site.mail.connections.storyteller.from}>";
        smtpSsl = false;
        smtpRejectUnauthorized = true;
      } // lib.optionalAttrs has-hardcover-token {
        hardcoverApiToken_file = storyteller.secrets.hardcover-token.credential;
      });
      ENABLE_WEB_READER = "true";
      HOME = storyteller.dir;
      # OIDC (trustHost is hardcoded true in Storyteller)
      AUTH_URL = "${storyteller.url}/api/v2/auth";
      NEXT_CACHE_DIR = "%C/storyteller";
    };
    preStart = ''
      if [ ! -s ${storyteller.dir}/secret_key ]; then
        umask 077
        head -c 32 /dev/urandom | base64 > ${storyteller.dir}/secret_key
      fi
    '';
    serviceConfig = {
      User = "storyteller";
      Group = "storyteller";
      ExecStart = "${storyteller-pkg}/bin/storyteller";
      Restart = "on-failure";
      RestartSec = 10;
      StateDirectory = "storyteller";
      CacheDirectory = "storyteller";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      LimitNOFILE = 65536;
    };
  };

  users.users.storyteller = {
    isSystemUser = true;
    group = "storyteller";
    extraGroups = [ "users" "video" "render" ];
  };

  users.groups.storyteller = { };

  services.caddy.virtualHosts.${storyteller.domain}.extraConfig = ''
    root ${config.site.assets}/storyteller
    route /favicon.ico {
        file_server
    }
    route /Storyteller_Logo.png {
        rewrite * /logo.png
        file_server
    }
    reverse_proxy 127.0.0.1:${toString storyteller.port}
  '';
}
