{ config, lib, site-lib, ... }:

# The site's shared databases: one Postgres and one Valkey that apps on any host reach over the
# mesh. On its own, a plain instance of each runs on site.databases.host; with site.ha.preference
# set, the high-availability modules serve them replicated instead, setting site.databases.servers.
# Apps declare what they use here, and the servers' clients and secrets follow.

let
  databases = config.site.databases;
  servers = databases.servers;
  inherit (servers) postgres valkey;
  inherit (config.site) ha hosts;
  this-host = config.site.server.host;
  derived = description: default: lib.mkOption { readOnly = true; inherit description default; };
  units = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf (lib.types.enum hosts));
    default = { };
    description = "The units connecting, each with the hosts it runs on";
  };
  merge-units = lib.zipAttrsWith (_: hosts: lib.unique (lib.concatLists hosts));
  clients-of = declared: merge-units (lib.mapAttrsToList (_: d: d.units) declared);
in {
  options.site.databases = {
    host = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum hosts);
      default = if lib.length hosts == 1 then lib.head hosts else null;
      defaultText = "the site's only host, if it has one";
      description = "The host keeping the shared databases when site.ha.preference is empty";
    };
    replicated = derived "Whether the high-availability modules replicate the shared databases"
      (ha.preference != [ ]);
    hosts = derived "The hosts that may serve the shared databases, most preferred first"
      (if databases.replicated then ha.preference else lib.optional (databases.host != null) databases.host);
    primary = derived "The most preferred of site.databases.hosts"
      (if databases.hosts == [ ] then null else lib.head databases.hosts);
    may-serve = derived "Whether this host may serve the shared databases, and so runs every app beside the primary"
      (lib.elem this-host databases.hosts);
    servers = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      default = {
        inherit (databases) hosts;
        postgres = { unit = "postgresql"; port = 5432; socket-dir = "/run/postgresql"; };
        valkey = { unit = "redis-shared"; port = 6380; };
        primary-env = "/etc/databases/primary.env";
      };
      description = ''
        How the shared databases are served: the `hosts` running its servers, each store's `unit` and
        `port`, Postgres's `socket-dir`, and the `primary-env` file naming the primary to units,
        as DB_PRIMARY, the serving host as DB_SERVING, and its Postgres as PGHOST and PGPORT.
      '';
    };
    primary-proxy = derived ''
      A Caddy directive proxying to ports, tried in turn, on whichever host serves the shared
      data: for an app beside the primary alone, reachable through every host.
    '' (ports: let
      on = host: map (port: if databases.replicated || host != this-host then "${host}.internal:${toString port}"
        else ":${toString port}") (lib.toList ports);
    in config.site.proxy-to (lib.concatMap on databases.hosts));
    postgres = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.units = units // {
          description = "The units connecting, each with its hosts, as a system user of the database's name";
        };
        # the nearest standby may be a continent away
        options.local-commits = lib.mkEnableOption "commits that return without waiting for a standby";
      });
      default = { };
      description = "The Postgres databases, by name, each owned by a role of that name";
    };
    valkey = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.units = units;
        options.acl = lib.mkOption {
          type = lib.types.str;
          example = "~app:* resetchannels +@read +@write";
          description = "Its keys, channels and commands, as Valkey's ACL rules";
        };
      });
      default = { };
      description = ''
        The Valkey users, by name, each with a password from keys/valkey-<name>.age; `default` is
        Valkey's own, whose password the servers share.
      '';
    };
  };

  # Unreplicated, Valkey is the NixOS module's, which sets the default user's password alone
  config.assertions = [ {
    assertion = databases.replicated || lib.attrNames databases.valkey == [ "default" ];
    message = "site.databases.valkey declares ${toString (lib.remove "default" (lib.attrNames databases.valkey))}, "
      + "but the unreplicated Valkey serves its default user alone; connect as that, or set site.ha.preference";
  } ];
  config.site = {
    databases.valkey.default = {
      units.${valkey.unit} = servers.hosts;
      acl = "~* &* +@all";
    };
    ports = {
      postgres = site-lib.mesh postgres.port postgres.unit (clients-of databases.postgres) // { inherit (servers) hosts; };
      # Postgres asks each client's host on 113, which it can't be told otherwise
      ident = site-lib.mesh 113 "oidentd" { ${postgres.unit} = servers.hosts; };
      valkey = site-lib.mesh valkey.port valkey.unit (clients-of databases.valkey) // { inherit (servers) hosts; };
    };
    secrets = lib.mapAttrs' (name: user: lib.nameValuePair "valkey-${name}" ({
      kind = "key";
      generate = "rand";
      units = merge-units [ user.units { ${valkey.unit} = servers.hosts; } ];
    } // lib.optionalAttrs (name == "default") { file-name = "valkey-ha"; })) databases.valkey;
  };
}
