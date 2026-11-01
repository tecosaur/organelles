{ config, options, lib, pkgs, site-lib, ... }:

let
  assets-pkg = pkgs.callPackage ./assets.nix {
    primary = config.site.accent.primary;
    secondary = config.site.accent.secondary;
  };
in {
  imports = [ ./network.nix ./secrets.nix ];

  options.site = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Global domain name for the site";
    };
    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "golgi" "nucleus" ];
      description = ''
        Every machine in the site, this one included. A host's mesh address is
        derived from its name alone (see site.mesh.subnet), so naming a machine
        here is all it takes to place it on the mesh.
      '';
    };
    mesh = {
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "fd00:c1de::";
        description = ''
          IPv6 ULA prefix for the inter-node mesh, which must not collide with
          the tailnet. A host takes the address formed by appending the first
          16 bits of the SHA-256 of its name, so an address depends on that one
          name and nothing else: adding, removing or renaming a machine leaves
          every other host's address untouched.
        '';
      };
      addresses = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = lib.genAttrs config.site.hosts (name:
          "${config.site.mesh.subnet}${builtins.substring 0 4 (builtins.hashString "sha256" name)}");
        defaultText = lib.literalMD "derived from `site.hosts` and `site.mesh.subnet`";
        description = "Every host's mesh address, by host name";
      };
    };
    dns = {
      host-domain = lib.mkOption {
        type = lib.types.str;
        default = "hosts";
        description = ''
          Label under which each host's own record lives, kept current by
          dns-pooler: golgi.hosts.example.com. Deploys and the mesh reach hosts
          by these names.
        '';
      };
      records = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              example = "@";
              description = "Name relative to the site domain; @ is the apex";
            };
            type = lib.mkOption {
              type = lib.types.str;
              example = "MX";
              description = "Record type";
            };
            value = lib.mkOption {
              type = lib.types.str;
              example = "10 mail.example.com.";
              description = "Record data in presentation form";
            };
          };
        });
        default = [ ];
        description = ''
          Records the site declares outright rather than any host serving: mail,
          verification, DKIM and the like. dns-pooler asserts them, and deletes
          any record in the zone that is neither declared nor derived nor
          ignored.
        '';
      };
      ignore = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "_acme-challenge" "_acme-challenge.*" ];
        description = ''
          Globs of names dns-pooler never touches, for records something else
          maintains. The default leaves Caddy's ACME challenges alone; `*`
          matches dots too.
        '';
      };
      served = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        internal = true;
        description = ''
          The names each host's Caddy serves, relative to the site domain, set
          from every machine's configuration by the flake. dns-pooler points
          each at its host.
        '';
      };
    };
    status = {
      units = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Stable identifier, unique on its host";
            };
            name = lib.mkOption {
              type = lib.types.str;
              description = "How the status page names it";
            };
            kind = lib.mkOption {
              type = lib.types.enum [ "service" "mesh" ];
              default = "service";
              description = ''
                A systemd service, or the mesh as the local dns-pooler sees
                its peers.
              '';
            };
            unit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "caddy.service";
              description = "The systemd unit, for a service";
            };
            command = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                A readiness probe that must exit zero for the running unit to
                count as healthy, such as pg_isready.
              '';
            };
          };
        });
        default = [ ];
        description = ''
          This host's infrastructure, shown beside its apps on the status
          page: what no app accounts for, but everything relies on.
        '';
      };
      fleet-units = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.attrs);
        default = { };
        internal = true;
        description = ''
          Every host's status units, by host, set from every machine's
          configuration by the flake.
        '';
      };
    };
    accent = {
      primary = lib.mkOption {
        type = lib.types.str;
        default = "#4F46E5";
        description = "Primary accent color in hex format";
      };
      secondary = lib.mkOption {
        type = lib.types.str;
        default = "#9333EA";
        description = "Secondary accent color in hex format";
      };
    };
    assets = lib.mkPackageOption { site-assets = assets-pkg; } "site-assets" { };
    server = {
      admin = {
        hashedPassword = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Hashed password for the admin user";
        };
        authorizedKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "SSH public keys for the admin user";
        };
      };
      authoritative = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this server is authoritative for the domain";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Server name";
      };
      ipv6 = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "IPv6 address for the server";
      };
    };
  };

  config = {
    site.apps = lib.mapAttrs (name: _: let domain = "${config.site.apps.${name}.subdomain}.${config.site.domain}"; in {
      inherit domain;
      url = "https://${domain}";
    }) options.site.apps;
    site.ports.wireguard = site-lib.public 51820 "systemd-networkd" // { protocols = [ "udp" ]; };
    # each host's mesh key, for it alone, readable by networkd as systemd.netdev(5) asks
    site.secrets = lib.listToAttrs (map (host: lib.nameValuePair "wg-${host}" {
      kind = "key"; generate = "wireguard"; recipients = [ host ];
      group = "systemd-network"; mode = "0640";
    }) config.site.hosts);
    assertions = let
      subdomains = lib.mapAttrsToList (name: app: { inherit name; inherit (app) subdomain; })
        (lib.filterAttrs (_: app: app.enabled) config.site.apps);
      contested = lib.filterAttrs (_: claimants: lib.length claimants > 1)
        (lib.groupBy (claim: claim.subdomain) subdomains);
    in [ {
      assertion = contested == { };
      message = "site.apps: ${lib.concatStringsSep "; " (lib.mapAttrsToList (subdomain: claimants:
        "subdomain ${subdomain} claimed by ${lib.concatMapStringsSep ", " (claim: claim.name) claimants}") contested)}; "
        + "subdomains share one domain, so give one of them a distinct name in its site.nix";
    } ];
  };
}
