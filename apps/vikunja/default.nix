{ config, lib, pkgs, ... }:

let
  app = config.site.apps.vikunja;
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
    frontendHostname = app.domain;
    port = app.port;
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
          redirecturl = "${app.url}/auth/openid/";
          providers = {
            authelia = {
              name = "Authelia";
              authurl = config.site.apps.authelia.url;
              clientid = "vikunja";
              clientsecret.file = app.auth.clients.vikunja.secret.credential;
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

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    @public-assets path /favicon.ico /images/icons/*
    route {
        file_server @public-assets {
            root ${config.site.assets}/vikunja/public
        }
        reverse_proxy :${toString app.port}
    }
    '';
}
