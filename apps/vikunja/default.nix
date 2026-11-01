{ config, lib, pkgs, ... }:

let
  vikunja-domain = "${config.site.apps.vikunja.subdomain}.${config.site.domain}";
  vikunja-user = "vikunja";
  vikunja-assets = builtins.path {
    name = "vikunja-assets";
    path = "${config.site.assets}/vikunja";
  };
in {
  site.apps.vikunja.enabled = true;

  services.vikunja = {
    enable = true;
    package = pkgs.callPackage ./package.nix {
      vikunja-assets = vikunja-assets;
    };
    frontendScheme = "https";
    frontendHostname = vikunja-domain;
    port = config.site.apps.vikunja.port;
    database = {
      type = "postgres";
      user = vikunja-user;
      host = "/run/postgresql";
    };
    settings = {
      auth = {
        local.enabled = false;
        openid = {
          enabled = true;
          redirecturl = "https://${vikunja-domain}/auth/openid/";
          providers = {
            authelia = {
              name = "Authelia";
              authurl = "https://${config.site.apps.authelia.subdomain}.${config.site.domain}";
              clientid = "vikunja";
              clientsecret.file = config.site.apps.vikunja.auth.clients.vikunja.secret.credential;
            };
          };
        };
      };
      service = {
        enableuserdeletion = false;
      };
      mailer = {
        enabled = true;
        inherit (config.site.mail.connections.vikunja) host port;
        fromemail = config.site.mail.connections.vikunja.from;
      };
      defaultsettings = {
        discoverable_by_name = true;
        week_start = 1;
      };
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ config.services.vikunja.database.user ];
    ensureUsers = [
      { name = config.services.vikunja.database.user;
        ensureDBOwnership = true;
      }
    ];
  };

  users.users.${vikunja-user} = {
    group = vikunja-user;
    isSystemUser = true;
  };
  users.groups.${vikunja-user} = {};

  services.caddy.virtualHosts."${vikunja-domain}".extraConfig =
    ''
    @public-assets path /favicon.ico /images/icons/*
    route {
        file_server @public-assets {
            root ${config.site.assets}/vikunja/public
        }
        reverse_proxy :${toString config.site.apps.vikunja.port}
    }
    '';
}
