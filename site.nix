{ config, lib, pkgs, ... }:

let
  # The shape every listener is declared in, so the firewall, the port-clash
  # check and confinement read them all alike
  listener = { unit ? null, hosts ? null, exposure ? "local" }:
    lib.types.submodule {
      options = {
        port = lib.mkOption {
          type = lib.types.port;
          description = "Port it listens on";
        };
        unit = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = unit;
          description = "The systemd service listening";
        };
        hosts = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = hosts;
          description = "Hosts it listens on; null for those running its owner";
        };
        exposure = lib.mkOption {
          type = lib.types.enum [ "local" "mesh" "public" ];
          default = exposure;
          description = ''
            Who may connect: units on the same host, other hosts over the mesh,
            or anyone, for which the firewall opens it.
          '';
        };
        protocols = lib.mkOption {
          type = lib.types.listOf (lib.types.enum [ "tcp" "udp" ]);
          default = [ "tcp" ];
          description = "Transport protocols it accepts";
        };
      };
    };
  mkAppOption = { name, description, homepage, simpleicon ? null,
                  service ? (lib.toLower (lib.replaceStrings [ " " ] [ "-" ] name)),
                  usesStateDir ? (service != null),
                  subdomain, port, admin ? "admin", extra-groups ? [],
                  auth ? {}, cacheSubdirs ? [], stateSubdirs ? null, health ? null,
                  followsPrimary ? false, exposure ? (if followsPrimary then "mesh" else "local"),
                  ports ? {}, extraOptions ? {} }:
    {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "How ${name} is known by.";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = description;
        description = "Description of the ${name} app";
      };
      homepage = lib.mkOption {
        type = lib.types.str;
        default = homepage;
        description = "Link to the homepage/documentation for ${name}";
      };
      simpleicon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = simpleicon;
        description = "Simple icon for the ${name} app";
      };
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether ${name} has been enabled, set by modules enabling it";
      };
      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = service;
        description = "The systemd service for the ${name} app. Set to null if stateless";
      };
      usesStateDir = lib.mkOption {
        type = lib.types.bool;
        default = usesStateDir;
        description = "Whether the ${name} app uses a state directory";
      };
      serviceConfig = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "The systemd service configuration for the ${name} app";
      };
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host that the ${name} app is running on";
      };
      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Every host the ${name} app runs on, set by the flake from each
          machine's configuration; `host` names only one of them.
        '';
      };
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = subdomain;
        description = "Name for the ${name} app";
      };
      dir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/${lib.toLower (if service != null then service else name)}";
        description = "Directory where the ${name} app stores its data";
      };
      cacheSubdirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cacheSubdirs;
        description = "List of subdirectories in the ${name} app data directory to be treated as cache";
      };
      stateSubdirs = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = stateSubdirs;
        example = [ "data" "uploads" ];
        description = ''
          Subdirectories of the ${name} app state directory holding data worth
          keeping, when only some of it is. Null puts the whole state directory
          on bulk storage, which is right until part of it is derived.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = port;
        description = "Port of the ${name} app's main listener, which Caddy proxies";
      };
      exposure = lib.mkOption {
        type = lib.types.enum [ "local" "mesh" "public" ];
        default = exposure;
        description = "Who may reach the main listener; see `ports`";
      };
      ports = lib.mkOption {
        type = lib.types.attrsOf (listener { unit = service; });
        default = ports;
        description = ''
          The ${name} app's other listeners, its helpers' included, by name.
          Nothing of the app listens on a port not declared here or as `port`.
        '';
      };
      followsPrimary = lib.mkOption {
        type = lib.types.bool;
        default = followsPrimary;
        description = ''
          Whether the ${name} app runs beside the replicated Postgres primary
          alone, every host's Caddy proxying to it there.
        '';
      };
      health = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/api/health";
              description = "Path requested on the app's port, over plain HTTP to localhost; null for none";
            };
            status = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Expected status; null accepts any 2xx";
            };
            body = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Regular expression the response body must match";
            };
            ports = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  listener = lib.mkOption {
                    type = lib.types.str;
                    example = "smtp";
                    description = "The listener in `ports` connected to, on localhost";
                  };
                  tls = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Whether to also verify the certificate for the app's name on it";
                  };
                };
              });
              default = [ ];
              example = [ { listener = "smtp"; } { listener = "imaps"; tls = true; } ];
              description = "Further listeners that must accept a TCP connection";
            };
            startupGrace = lib.mkOption {
              type = lib.types.ints.positive;
              default = 120;
              description = ''
                Seconds a fresh start may fail this check before the status
                page counts it as unhealthy rather than starting.
              '';
            };
          };
        });
        default = health;
        description = ''
          How dns-pooler checks the ${name} app is serving, beside its systemd
          unit. Null relies on the unit alone, which misses a process that runs
          without serving.
        '';
      };
      groups = {
        admin = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = admin;
          description = "User group that has admin access to the ${name} app";
        };
        primary = lib.mkOption {
          type = lib.types.str;
          default = lib.toLower name;
          description = "Primary user group for the ${name} app";
        };
        extra = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = extra-groups;
          description = "Additional user groups that have access to the ${name} app";
        };
      };
    } // extraOptions;
  assets-pkg = pkgs.callPackage ./packages/site-assets.nix {
    primary = config.site.accent.primary;
    secondary = config.site.accent.secondary;
  };
in {
  options.site = {
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
    apps = {
      authelia = mkAppOption {
        health.path = "/api/health";
        name = "Authelia";
        homepage = "https://www.authelia.com";
        description = "authentication and SSO portal";
        simpleicon = "authelia";
        # Named for its status checks; it keeps no state of its own
        service = "authelia-main";
        usesStateDir = false;
        subdomain = "auth";
        port = 9091;
        # the other hosts' Caddy proxy /api/* to it
        exposure = "mesh";
      };
      beszel = mkAppOption {
        health.path = "/api/health";
        name = "Beszel";
        homepage = "https://beszel.dev";
        description = "System monitoring";
        service = "beszel-hub";
        subdomain = "systems";
        port = 8090;
        # beszel-agent is a core module, beside the hub or not
        ports.agent = { port = 45876; unit = "beszel-agent"; hosts = config.site.hosts; };
        admin = null;
        extra-groups = [ "admin" ];
        extraOptions = {
          publicKey = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Public key of the Beszel hub";
          };
          extra-filesystems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional filesystems the agent should monitor";
          };
          systems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "List of system hosts, that have Beszel agents";
          };
        };
      };
      dawarich = mkAppOption {
        health.path = "/api/v1/health";
        name = "Dawarich";
        homepage = "https://dawarich.com";
        description = "location timeline";
        service = "dawarich-web";
        subdomain = "timeline";
        port = 6805;
      };
      fava = mkAppOption {
        health = { path = "/"; status = 302; };
        name = "Fava";
        homepage = "https://beancount.github.io/fava/";
        description = "Beancount web interface";
        service = "fava";
        usesStateDir = false;
        subdomain = "fava";
        port = 5025;
      };
      forgejo = mkAppOption {
        health.path = "/api/healthz";
        name = "Forgejo";
        homepage = "https://forgejo.org";
        description = "personal software forge";
        simpleicon = "forgejo";
        subdomain = "code";
        port = 3002;
        extraOptions = {
          site-name = lib.mkOption {
            type = lib.types.str;
            default = "Forgejo";
            description = "Name of the Forgejo instance";
          };
          site-description = lib.mkOption {
            type = lib.types.str;
            default = "Forgejo instance";
            description = "Description of the Forgejo instance";
          };
          default-user-redirect = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "A private user to redirect to upon visiting the root domain";
          };
          qa-captcha = {
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable the question and answer captcha for the Forgejo registration page";
            };
            questions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Question to use for the Forgejo registration captcha";
            };
            answers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "List of acceptable answers for the Forgejo registration captcha";
            };
          };
          served-repositories = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                repo = lib.mkOption {
                  type = lib.types.str;
                  description = "Path to the repository";
                };
                rev = lib.mkOption {
                  type = lib.types.str;
                  description = "Branch, tag, or commit to serve";
                };
                subdomain = lib.mkOption {
                  type = lib.types.str;
                  default = "pages";
                  description = "Subdomain to serve the repository on";
                };
                path = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "URL prefix to serve the repository on";
                };
              };
            });
            default = [ ];
          };
        };
      };
      jellyfin = mkAppOption {
        health.path = "/health";
        name = "Jellyfin";
        homepage = "https://jellyfin.org";
        description = "media server";
        simpleicon = "jellyfin";
        subdomain = "media";
        port = 8096;
        # LAN and TV clients connect directly
        exposure = "public";
        ports.dlna = { port = 1900; protocols = [ "udp" ]; exposure = "public"; };
      };
      headscale = mkAppOption {
        health.path = "/health";
        name = "Headscale";
        homepage = "https://headscale.net";
        description = "mesh virtual private network";
        subdomain = "headscale";
        port = 8174;
        ports = {
          headplane = { port = 8175; unit = "headplane"; };
          # every host's tailscaled relays for the tailnet
          relay = { port = 40108; unit = "tailscaled"; hosts = config.site.hosts; exposure = "public"; protocols = [ "tcp" "udp" ]; };
        };
        admin = null;
        extraOptions = {
          magicdns-subdomain = lib.mkOption {
            type = lib.types.str;
            default = "on";
            description = "Subdomain to use in the base domain for MagicDNS.";
          };
        };
      };
      home-assistant = mkAppOption {
        health.path = "/manifest.json";
        name = "Home Assistant";
        homepage = "https://www.home-assistant.io";
        description = "home automation";
        simpleicon = "homeassistant";
        subdomain = "homeassistant";
        port = 8123;
        stateSubdirs = [ "state" ".storage" "blueprints" ];
      };
      immich = mkAppOption {
        health.path = "/api/server/ping";
        name = "Immich";
        homepage = "https://immich.app";
        description = "photo and video management";
        simpleicon = "immich";
        service = "immich-server";
        usesStateDir = false;
        subdomain = "photos";
        port = 2283;
        ports.machine-learning = { port = 3003; unit = "immich-machine-learning"; };
      };
      llm = mkAppOption {
        health.path = "/health";
        name = "llama-cpp";
        homepage = "https://github.com/ggml-org/llama.cpp";
        description = "LLM inference endpoint";
        usesStateDir = false;
        subdomain = "llm";
        port = 8089;
        ports.embedding = { port = 8088; unit = "llama-cpp-embedding"; };
        extraOptions = {
          local = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to run a local llama-server, and serve it as an endpoint";
          };
          local-fallback = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Whether the local endpoint should only be used when every remote
              endpoint is unhealthy, instead of participating in load balancing.
            '';
          };
          proxy = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "workstation.lan:8089" "192.168.1.20:8089" ];
            description = ''
              Remote llama-server endpoints (as host:port) to serve alongside
              any local endpoint, subject to active health checking.
            '';
          };
          embedding = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = config.site.apps.llm.enabled;
              defaultText = lib.literalExpression "config.site.apps.llm.enabled";
              description = ''
                Whether to run a second, local llama-server dedicated to
                embeddings, serving /v1/embeddings on the same domain.
              '';
            };
          };
        };
      };
      ntfy = mkAppOption {
        health = { path = "/v1/health"; body = ''"healthy":true''; };
        name = "Ntfy";
        homepage = "https://ntfy.sh";
        description = "push notifications";
        simpleicon = "ntfy";
        service = "ntfy-sh";
        subdomain = "ntfy";
        port = 2586;
      };
      mail = mkAppOption {
        name = "Mail";
        homepage = "https://stalw.art";
        description = "mail server and web client";
        service = "stalwart";
        # its state lives in the replicated Postgres instance and the blob store
        usesStateDir = false;
        subdomain = "mail";
        port = 8460;
        # for the other hosts' Caddy alone, since it trusts X-Forwarded-For
        exposure = "mesh";
        ports = let
          inherit (config.site.mail.storage) heads;
          cluster-hosts = cluster: lib.attrNames config.site.mail.storage.${cluster};
          # a lone node keeps its RPC to itself
          rpc = cluster: port: {
            inherit port;
            unit = "garage";
            hosts = cluster-hosts cluster;
            exposure = if lib.length (cluster-hosts cluster) > 1 then "mesh" else "local";
          };
        in lib.mapAttrs (_: port: { inherit port; exposure = "public"; })
          { smtp = 25; submissions = 465; submission = 587; imaps = 993; sieve = 4190; }
        // {
          bulwark = { port = 3480; unit = "bulwark"; };
          # applies the settings before each start
          stalwart-recovery.port = 8461;
          s3-gateway = { port = 3920; unit = "s3-overflow"; };
          s3-gateway-status = { port = 3921; unit = "s3-overflow"; };
          garage-primary-s3 = { port = 3900; unit = "garage"; hosts = [ heads.primary ]; exposure = "mesh"; };
          garage-primary-rpc = rpc "primary" 3901;
          garage-overflow-s3 = { port = 3910; unit = "garage"; hosts = [ heads.overflow ]; exposure = "mesh"; };
          garage-overflow-rpc = rpc "overflow" 3911;
        };
        health.ports = [ { listener = "smtp"; } { listener = "imaps"; tls = true; } ];
      };
      mealie = mkAppOption {
        health.path = "/api/app/about";
        name = "Mealie";
        homepage = "https://docs.mealie.io";
        description = "recipe manager";
        subdomain = "mealie";
        port = 9000;
      };
      memos = mkAppOption {
        health.path = "/healthz";
        name = "Memos";
        homepage = "https://usememos.com";
        description = "quick notes";
        subdomain = "memos";
        port = 5230;
      };
      microbin = mkAppOption {
        health.path = "/";
        name = "Microbin";
        homepage = "https://github.com/szabodanika/microbin";
        description = "pastebin and url shortener";
        subdomain = "microbin";
        port = 4144;
        extraOptions = {
          title = lib.mkOption {
            type = lib.types.str;
            default = "Microbin";
            description = "Title of the Microbin app";
          };
          short-subdomain = lib.mkOption {
            type = lib.types.str;
            default = "bin";
            description = "Short subdomain for Microbin";
          };
        };
      };
      paperless = mkAppOption {
        health.path = "/accounts/login/";
        name = "Paperless";
        homepage = "https://paperless-ngx.readthedocs.io";
        description = "document management";
        simpleicon = "paperlessngx";
        service = "paperless-web";
        subdomain = "folio";
        port = 28981;
        ports = {
          tika = { port = 9998; unit = "tika"; };
          gotenberg = { port = 3000; unit = "gotenberg"; };
        };
      };
      rustical = mkAppOption {
        health.path = "/ping";
        name = "Rustical";
        homepage = "https://rustical.app";
        description = "calendar and contacts server";
        subdomain = "cal";
        port = 4811;
      };
      scrutiny = mkAppOption {
        health.path = "/api/health";
        name = "Scrutiny";
        homepage = "https://github.com/AnalogJ/scrutiny";
        description = "disk health monitoring";
        subdomain = "drives.health";
        port = 8606;
        ports.influxdb = { port = 8086; unit = "influxdb2"; };
      };
      sftpgo = mkAppOption {
        health.path = "/healthz";
        name = "SFTPGo";
        homepage = "https://sftpgo.com";
        description = "SFTP server";
        subdomain = "files";
        port = 8083;
        ports = {
          sftp = { port = 2022; exposure = "public"; };
          webdav.port = 3303;
        };
        admin = null;
      };
      speedtest = mkAppOption {
        health.path = "/backend/empty";
        name = "Speedtest";
        homepage = "https://openspeedtest.com";
        description = "connection speed testing";
        service = "librespeed";
        usesStateDir = false;
        subdomain = "speed";
        port = 8076;
      };
      storyteller = mkAppOption {
        health.path = "/api/health";
        name = "Storyteller";
        homepage = "https://storyteller-platform.gitlab.io/storyteller/";
        description = "synced audiobook platform";
        subdomain = "books";
        port = 8001;
        ports.readium.port = 8002;
        cacheSubdirs = [ ".cache" ".local" "image-cache" ];
      };
      syncthing = mkAppOption {
        health.path = "/rest/noauth/health";
        name = "Syncthing";
        homepage = "https://syncthing.net";
        description = "folder synchronisation";
        simpleicon = "syncthing";
        subdomain = "syncthing";
        port = 8384;
      };
      tandoor = mkAppOption {
        name = "Tandoor";
        homepage = "https://tandoor.dev";
        description = "recipe manager";
        service = "tandoor-recipes";
        subdomain = "recipes";
        port = 7203;
      };
      trek = mkAppOption {
        health.path = "/api/health";
        name = "Trek";
        homepage = "https://github.com/liketrek/TREK";
        description = "collaborative travel planner";
        subdomain = "travel";
        port = 8054;
        # The rest of the state directory is a tree of links to the store,
        # rebuilt on every start.
        stateSubdirs = [ "data" "uploads" ];
      };
      koito = mkAppOption {
        health.path = "/apis/web/v1/health";
        name = "Koito";
        homepage = "https://koito.io";
        description = "listening history";
        subdomain = "listens";
        port = 4110;
        extraOptions = {
          title = lib.mkOption {
            type = lib.types.str;
            default = "Koito";
            description = "Title of the Koito app";
          };
        };
      };
      multi-scrobbler = mkAppOption {
        # the Koito client alone: the full check fails whenever any upstream
        # scrobbling service is down
        health.path = "/api/health?type=koito";
        name = "Multi-Scrobbler";
        homepage = "https://foxxmd.github.io/multi-scrobbler";
        description = "scrobble collector";
        subdomain = "scrobbler";
        port = 9078;
        extraOptions = {
          jellyfin-user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The Jellyfin account whose plays are scrobbled";
          };
          listenbrainz-user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The ListenBrainz account listens are relayed to";
          };
        };
      };
      transmission = mkAppOption {
        name = "Transmission";
        homepage = "https://transmissionbt.com";
        description = "torrent client";
        simpleicon = "transmission";
        subdomain = "torrent";
        port = 9092;
        exposure = "public";
        ports.peer = { port = 58193; exposure = "public"; };
        stateSubdirs = [ ".config/transmission-daemon" ];
      };
      lldap = mkAppOption {
        health.path = "/health";
        name = "LLDAP";
        homepage = "https://github.com/lldap/lldap";
        description = "user account management";
        followsPrimary = true;
        subdomain = "users";
        port = 17170;
        ports.ldap = { port = 3890; exposure = "mesh"; };
      };
      gatus = mkAppOption {
        health = { path = "/health"; body = ''"status":"UP"''; };
        name = "Gatus";
        homepage = "https://gatus.io";
        description = "status page";
        followsPrimary = true;
        # its history lives in the replicated Postgres instance
        usesStateDir = false;
        subdomain = "status";
        port = 3001;
      };
      vaultwarden = mkAppOption {
        health.path = "/alive";
        name = "Vaultwarden";
        homepage = "https://github.com/dani-garcia/vaultwarden";
        description = "password manager";
        simpleicon = "vaultwarden";
        followsPrimary = true;
        stateSubdirs = [ "attachments" "sends" ];
        subdomain = "vault";
        port = 8222;
      };
      vikunja = mkAppOption {
        name = "Vikunja";
        homepage = "https://vikunja.io/";
        description = "task and project management";
        subdomain = "tasks";
        port = 3456;
      };
      warracker = mkAppOption {
        health.path = "/api/health";
        name = "Warracker";
        homepage = "https://warracker.com";
        description = "warranty tracking";
        subdomain = "warracker";
        port = 8087;
      };
    };
  };

  config = let
    this-host = config.site.server.host;
    on-this-host = hosts: hosts != null && lib.elem this-host hosts;
    # Every listener on this host: an app's own where it runs, and any naming
    # its hosts wherever those are
    app-listeners = lib.concatLists (lib.mapAttrsToList (name: app: let
      runs-here = lib.elem this-host app.hosts;
    in lib.optional runs-here { inherit name; inherit (app) port exposure; protocols = [ "tcp" ]; }
       ++ lib.mapAttrsToList (listener-name: listener: listener // { name = "${name} ${listener-name}"; })
            (lib.filterAttrs (_: listener: if listener.hosts == null then runs-here else on-this-host listener.hosts) app.ports))
      (lib.filterAttrs (_: app: app.enabled) config.site.apps));
    listeners-here = app-listeners ++ lib.mapAttrsToList (name: listener: listener // { inherit name; })
      (lib.filterAttrs (_: listener: on-this-host listener.hosts) config.site.ports);
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
  site.ports = let
    inherit (config.site.ha) preference;
    mesh = port: unit: { inherit port unit; exposure = "mesh"; };
    public = port: unit: { inherit port unit; exposure = "public"; };
  in {
    ssh = public 22 "sshd";
    http = public 80 "caddy";
    https = public 443 "caddy" // { protocols = [ "tcp" "udp" ]; };
    wireguard = public 51820 "systemd-networkd" // { protocols = [ "udp" ]; };
    tailscale = public 41641 "tailscaled" // { protocols = [ "udp" ]; };
    # a host's own modules add it where it answers
    mdns = public 5353 "systemd-resolved" // { protocols = [ "udp" ]; hosts = lib.mkDefault [ ]; };
    dns-pooler-peer = mesh 9433 "dns-pooler";
    dns-pooler-status = { port = 9434; unit = "dns-pooler"; };
    # each reporter's board of planned transitions
    status-conditions = mesh 9435 "gatus-aggregator-report";
    # the aggregator's answer to the page's /api/v1/config
    status-announcement = mesh 9436 "gatus-aggregator-aggregate";
    crowdsec-api = { port = 8057; unit = "crowdsec"; };
    slimproto = public 3483 "slimserver" // { protocols = [ "tcp" "udp" ]; };
    lyrion-web = public 9000 "slimserver";
    lyrion-cli = public 9090 "slimserver";
    postgres-ha = mesh 5433 "patroni";
    # Postgres asks each client's host on 113, which it can't be told otherwise
    ident = mesh 113 "oidentd";
    etcd = mesh 2379 "etcd";
    etcd-peer = mesh 2380 "etcd";
    patroni = mesh 8008 "patroni";
    # /serving answers 200 only on the serving member, for Caddy's health checks
    ha-serving = mesh 8009 "caddy" // { hosts = preference; };
    valkey-ha = mesh 6380 "valkey-ha";
    sentinel = mesh 26379 "valkey-ha-sentinel";
    meilisearch = mesh 7700 "meilisearch" // { hosts = [ config.site.meilisearch.host ]; };
  };
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
