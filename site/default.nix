{ config, lib, pkgs, site-lib, ... }:

let
  inherit (site-lib) listener;
  # A listener's clients as each unit with the hosts it runs on; a bare list
  # names units on the listener's own hosts
  client-hosts = hosts: clients: if lib.isList clients then lib.genAttrs clients (_: hosts) else clients;
  merge-clients = lib.zipAttrsWith (_: hosts: lib.unique (lib.concatLists hosts));
  probes = hosts: { dns-pooler = hosts; gatus-aggregator-report = hosts; };
  all-listeners = let
    of-app = name: app: let
      probed = if app.health == null then [ ] else map (check: check.listener) app.health.ports;
      main = {
        inherit name;
        inherit (app) port exposure hosts;
        unit = app.service;
        protocols = [ "tcp" ];
        clients = merge-clients ([
          { caddy = if app.exposure == "mesh" then config.site.hosts else app.hosts; }
          (client-hosts app.hosts app.clients)
        ] ++ lib.optional (app.health != null && app.health.path != null) (probes app.hosts));
      };
      extra = lib.mapAttrsToList (listener-name: listener: let
        hosts = if listener.hosts == null then app.hosts else listener.hosts;
      in listener // {
        name = "${name}-${listener-name}";
        inherit hosts;
        clients = merge-clients ([ (client-hosts hosts listener.clients) ]
          ++ lib.optional (lib.elem listener-name probed) (probes hosts));
      }) app.ports;
    in [ main ] ++ extra;
  in lib.concatLists (lib.mapAttrsToList of-app (lib.filterAttrs (_: app: app.enabled) config.site.apps))
    ++ lib.mapAttrsToList (name: listener: let
      # unfilled outside the flake's final evaluation
      hosts = if listener.hosts == null then [ ] else listener.hosts;
    in listener // { inherit name hosts; clients = client-hosts hosts listener.clients; }) config.site.ports;
  assets-pkg = pkgs.callPackage ./assets.nix {
    primary = config.site.accent.primary;
    secondary = config.site.accent.secondary;
  };
in {
  imports = [ ./settings.nix ];

  options.site = {
    listeners = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = all-listeners;
      description = ''
        Every listener in the site, from site.apps and site.ports alike, with
        its `hosts` resolved and its `clients` as each unit allowed to connect
        with the hosts it runs on: what the firewall and confinement act on.
      '';
    };
    ports = lib.mkOption {
      type = lib.types.attrsOf (listener { });
      default = { };
      description = ''
        Every listener that belongs to no app: the replicated substrate's, the
        mesh's, and the system's own. With site.apps.<app>.port and .ports it
        is every port the site listens on, and nothing else opens the
        firewall. A null `hosts` is filled in by the flake with the machines
        whose configuration runs the listener's unit.
      '';
    };
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
    email = {
      server = lib.mkOption {
        type = lib.types.str;
        default = "smtp.example.com";
        description = "SMTP server to use for sending email";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 587;
        description = "Port to use for the SMTP server";
      };
      username = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Username for the SMTP server";
      };
    };
  };

  config = let
    this-host = config.site.server.host;
    listeners-here = lib.filter (listener: lib.elem this-host listener.hosts) config.site.listeners;
    opened = exposure: protocol: lib.unique (map (listener: listener.port)
      (lib.filter (listener: listener.exposure == exposure && lib.elem protocol listener.protocols) listeners-here));
    firewall = config.networking.firewall;
    # an opening no listener here declares: a module or nixpkgs default opening on its own
    undeclared = opening: declared: lib.subtractLists declared (lib.unique opening);
    stray = lib.filterAttrs (_: ports: ports != [ ]) {
      "public TCP" = undeclared firewall.allowedTCPPorts (opened "public" "tcp");
      "public UDP" = undeclared firewall.allowedUDPPorts (opened "public" "udp");
      "wg0 TCP" = undeclared (firewall.interfaces.wg0.allowedTCPPorts or [ ]) (opened "mesh" "tcp");
      "wg0 UDP" = undeclared (firewall.interfaces.wg0.allowedUDPPorts or [ ]) (opened "mesh" "udp");
    };
  in {
  site.ports.wireguard = site-lib.public 51820 "systemd-networkd" // { protocols = [ "udp" ]; };
  networking.firewall = {
    allowedTCPPorts = opened "public" "tcp";
    allowedUDPPorts = opened "public" "udp";
    interfaces.wg0 = {
      allowedTCPPorts = opened "mesh" "tcp";
      allowedUDPPorts = opened "mesh" "udp";
    };
  };
  assertions = [ {
    assertion = stray == { };
    message = "site: ${this-host} opens ${lib.concatStringsSep "; " (lib.mapAttrsToList (what: ports:
      "${what} ${lib.concatMapStringsSep ", " toString ports}") stray)} with no listener declaring it; "
      + "declare it in site.ports or site.apps.<app>.ports, and turn off the module's own opening";
  } ] ++ (
    let
      subdomain-claims = lib.mapAttrsToList (name: app: { inherit name; inherit (app) subdomain; })
        (lib.filterAttrs (_: app: app.enabled) config.site.apps);
      clashes = field: claims:
        lib.filterAttrs (_: claimants: builtins.length claimants > 1)
          (lib.groupBy (claim: toString claim.${field}) claims);
      describe = field: contested:
        lib.concatStringsSep "; " (lib.mapAttrsToList
          (value: claimants: "${field} ${value} claimed by "
                             + lib.concatStringsSep ", " (map (c: c.name) claimants))
          contested);
      contested-ports = clashes "port" listeners-here;
      contested-subdomains = clashes "subdomain" subdomain-claims;
    in [
      { assertion = contested-ports == { };
        message = "site.apps: ${describe "port" contested-ports} on ${config.site.server.host}; "
                  + "give one of them a free port in site.nix";
      }
      { assertion = contested-subdomains == { };
        message = "site.apps: ${describe "subdomain" contested-subdomains}; "
                  + "subdomains share one domain, so give one of them a distinct name in site.nix";
      }
    ]);
  };
}
