{ config, lib, pkgs, utils, ... }:

let
  app = config.site.apps.sftpgo;
  sftpgo-user = "sftpgo";
  sftpgo-pkg = pkgs.callPackage ./package.nix { };
  sftpgo-admin-user = "admin";
  webdav-prefix = "/dav";
  admin-password = app.secrets.admin-password.credential;
  sftpgo-exec = pkgs.writeShellScript "sftpgo-start" ''
    export SFTPGO_DEFAULT_ADMIN_USERNAME="${sftpgo-admin-user}"
    export SFTPGO_DEFAULT_ADMIN_PASSWORD="$(< ${admin-password})"
    exec ${sftpgo-pkg}/bin/sftpgo serve ${utils.escapeSystemdExecArgs config.services.sftpgo.extraArgs}
  '';
in {
  site.apps.sftpgo.enabled = true;

  site.unfree = [ "sftpgo" ];

  services.sftpgo = {
    enable = true;
    user = sftpgo-user;
    group = "users";
    package = sftpgo-pkg;
    extraReadWriteDirs = [ "/data/home" ];
    dataDir = app.dir;
    settings = {
      common = {
        upload_mode = 2;
        defender.enable = true;
        proxy_protocol = 1;
        proxy_allowed = [ "127.0.0.1" ];
        proxy_skipped = [ ];
      };
      data_provider = {
        driver = "sqlite";
        name = "sftpgo.db";
        create_default_admin = true;
        password_hashing = {
          algo = "argon2id";
          argon2_options = {
            memory = 65536;
            iterations = 3;
            parallelism = 4;
          };
        };
        password_caching = true;
      };
      webdavd.bindings = [
        {
          address = "127.0.0.1";
          port = app.ports.webdav.port;
          prefix = webdav-prefix;
          client_ip_proxy_header = "X-Forwarded-For";
          proxy_allowed = [ "127.0.0.1" ];
        }
      ];
      sftpd.bindings = [
        {
          port = app.ports.sftp.port;
          address = "0.0.0.0";
        }
      ];
      httpd.bindings = [
        {
          address = "127.0.0.1";
          enable_https = false;
          port = app.port;
          client_ip_proxy_header = "X-Forwarded-For";
          enable_web_admin = true;
          enable_web_client = true;
          enable_rest_api = true;
          enabled_login_methods = 6; # 0 = Anything, 1 = OIDC Admin, 2 = OIDC User, 4 = Form Admin, 8 = Form User
          proxy_allowed = [ "127.0.0.1" ];
          oidc = {
            client_id = "sftpgo";
            client_secret_file = app.auth.clients.sftpgo.secret.credential;
            config_url = config.site.apps.authelia.url;
            redirect_base_url = app.url;
            scopes = [ "openid" "email" "profile" "groups" ];
            query_userinfo = true;
            username_field = "preferred_username";
            custom_fields = [ "name" "email" ];
          };
          branding = {
            web_client = {
              name = "${config.site.domain}";
              short_name = "Files Web";
            };
            web_admin.short_name = "Files Admin";
          };
        }
      ];
    };
  };

  users.users.${sftpgo-user}.extraGroups =
    (lib.optional config.services.immich.enable "immich") ++
    (lib.optional config.services.paperless.enable "paperless");

  systemd.services.sftpgo.serviceConfig = {
    ExecStart = lib.mkForce sftpgo-exec;
    UMask = lib.mkForce "0007";
    Restart = "always";
    RestartSec = 5;
  };

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    encode
    header -Alt-svc
    @webdav path ${webdav-prefix} ${webdav-prefix}/*
    handle @webdav {
        reverse_proxy 127.0.0.1:${toString app.ports.webdav.port}
    }
    '';
}

  # -- Configuration --

  /*
Virtual folders:
- backedup: Local disk (/data/home/backedup)
- immich: Local disk (/data/immich/library)
- paperless: Local disk (/data/paperless/media/documents/archive)
- shared: Local disk (/data/home/shared)

Action(Auto-create users): Identity Provider account check/Create or update:
{
    "status": 1,
    "username": "{{.Name}}",
    "email": "{{.IDPFieldemail}}",
    "home_dir": "/data/home/{{.Name}}",
    "permissions": {
        "/": ["*"],
        "/Photos": ["list", "download", "copy"],
        "/Shared": ["list", "download", "copy"],
        "/Shared/{{.IDPFieldname}}": ["*"],
        "/Documents/Archive": ["list", "download", "copy"]
    },
    "virtual_folders": [
        {
            "name": "shared",
            "virtual_path": "Shared"
        },
        {
            "name": "shared",
            "virtual_path": "Public",
            "subpath": "{{.IDPFieldname}}"
        },
        {
            "name": "immich",
            "virtual_path": "Photos",
            "subpath": "{{.Name}}"
        },
        {
            "name": "paperless",
            "virtual_path": "Documents/Archive",
            "subpath": "{{.Name}}"
        }
    ]
}

Action(New user skeleton): Filesystem/Create directories:
/Backed up/{{.IDPFieldname}},/Shared/{{.IDPFieldname}}

Rule(Auto-create OIDC user): Identity Provider Logins/User login:
- Actions:
  - Auto-create users [synchronous]
*/
