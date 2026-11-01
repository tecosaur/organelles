{ lib }:

# The framework every app's and module's site.nix declares its metadata with: the app option
# and the listener shape, and constructors for the common listeners.

rec {
  clients-type = with lib.types; either (listOf str) (attrsOf (listOf str));
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
        clients = lib.mkOption {
          type = clients-type;
          default = [ ];
          example = { patroni = [ "golgi" "nucleus" ]; };
          description = ''
            Units that may connect: a list, for units on the hosts it listens on,
            or each unit with the hosts it runs on. The health probes are added
            for a listener an app's health check names.
          '';
        };
      };
    };
  mkAppOption = { name, description, homepage, simpleicon ? null,
                  service ? (lib.toLower (lib.replaceStrings [ " " ] [ "-" ] name)),
                  usesStateDir ? (service != null),
                  subdomain, port, admin ? "admin", extra-groups ? [],
                  auth ? {}, cacheSubdirs ? [], stateSubdirs ? null, health ? null,
                  followsPrimary ? false, exposure ? (if followsPrimary then "mesh" else "local"),
                  clients ? [], ports ? {}, extraOptions ? {} }:
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
      clients = lib.mkOption {
        type = clients-type;
        default = clients;
        description = ''
          Units reaching the main listener besides Caddy (from every host when
          it is on the mesh) and, given a health path, the health probes; in
          the form of a listener's `clients`.
        '';
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
      auth = {
        policy = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              users = lib.mkOption {
                type = lib.types.str;
                default = "one_factor";
                description = "What the app's users sign in with";
              };
              admins = lib.mkOption {
                type = lib.types.str;
                default = "two_factor";
                description = "What its admins sign in with";
              };
            };
          });
          default = auth.policy or null;
          description = ''
            The OIDC authorization policy named after the ${name} app, which
            its clients sign in under: its groups pass, by these factors,
            and others are denied. Null for none.
          '';
        };
        clients = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              redirects = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                example = [ "oidc/callback" "app.example:///callback" ];
                description = "Redirect paths under the app's domain, or whole URIs";
              };
              pkce = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether the client must use PKCE";
              };
              settings = lib.mkOption {
                type = lib.types.attrs;
                default = { };
                example = { token_endpoint_auth_method = "client_secret_post"; };
                description = "Further Authelia client settings, over the defaults";
              };
            };
          });
          default = auth.clients or { };
          description = ''
            The ${name} app's OIDC clients, by client ID, each signing in under
            the app's policy unless its settings say otherwise. A client's
            secret is secrets/oidc/<id>-secret.age, its digest beside it.
          '';
        };
        access = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              policy = lib.mkOption {
                type = lib.types.str;
                default = "one_factor";
                description = "What those allowed sign in with";
              };
              subject = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf lib.types.str);
                default = null;
                description = "Who is allowed; null for the app's primary and admin groups";
              };
            };
          });
          default = auth.access or null;
          description = ''
            Authelia's rule for routes Caddy guards with forward-auth on the
            ${name} app's domain: those allowed pass, and others are denied.
          '';
        };
      };
    } // extraOptions;
  mesh = port: unit: clients: { inherit port unit clients; exposure = "mesh"; };
  local = port: unit: clients: { inherit port unit clients; };
  public = port: unit: { inherit port unit; exposure = "public"; };
}
