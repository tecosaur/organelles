{ lib }:

# The framework every app's and module's site.nix declares its metadata with: the app option
# and the listener shape, and constructors for the common listeners.

rec {
  id-of = name: lib.toLower (lib.replaceStrings [ " " ] [ "-" ] name);
  # Each site.nix in a folder under the roots: every app's and module's metadata
  site-modules = roots: lib.concatMap (root: lib.concatMap (name:
      lib.optional (builtins.pathExists (root + "/${name}/site.nix")) (root + "/${name}/site.nix"))
    (lib.attrNames (builtins.readDir root))) roots;
  secret-dirs = { key = "keys"; credential = "credentials"; password = "passwords"; oidc = "oidc"; };
  # The shape every secret is declared in
  secret = { prefix ? null, kind ? null, file-name ? null, as ? null }: lib.types.submodule ({ name, config, ... }: {
    options = {
      kind = lib.mkOption ({
        type = lib.types.enum (lib.attrNames secret-dirs);
        description = ''
          Where it comes from, and so its directory under secrets/: a key
          the scripts generate, a credential from elsewhere, a password set
          by hand, or an OIDC client's secret beside its digest.
        '';
      } // lib.optionalAttrs (kind != null) { default = kind; });
      generate = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "rand" "hex" "rsa" "dkim" "s3-key" "garage-node" "meilisearch" "wireguard" ]);
        default = null;
        description = "How a key is generated; companion files sit beside it by name";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "What it is, and for a credential where to get it";
      };
      optional = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether its absence merely turns off what uses it";
      };
      recipients = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "The hosts that may decrypt it, besides the admin; null for every host";
      };
      file-name = lib.mkOption {
        type = lib.types.str;
        default = if file-name != null then file-name else if prefix == null then name else "${prefix}-${name}";
        description = "Its file's name in its directory, less .age";
      };
      units = lib.mkOption {
        type = with lib.types; either (listOf str) (attrsOf (listOf str));
        default = [ ];
        example = { gatus = [ "golgi" ]; gatus-aggregator-report = [ "golgi" "centrosome" ]; };
        description = ''
          The systemd units that read it, each loading it as a credential
          at the path `credentials.<unit>` gives, `credential` for the one:
          a list, for units on its hosts, or each unit with the hosts it
          runs on, which are then its hosts.
        '';
      };
      hosts = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          The hosts holding it; null for its units', else those it is
          encrypted to, else its app's, else every host; [ ] for none, as for
          a secret entered by hand in its app.
        '';
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Who owns the decrypted file, for a reader no credential reaches";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "The decrypted file's group";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0400";
        description = "The decrypted file's mode";
      };
      credential-name = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = if as != null then as else name;
        description = "Its name among a unit's credentials";
      };
      decrypted = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "/run/agenix/${config.file-name}";
        description = "The decrypted file, for root, an EnvironmentFile, or its owner";
      };
      credentials = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = lib.genAttrs (if lib.isList config.units then config.units else lib.attrNames config.units)
          (unit: "/run/credentials/${unit}.service/${config.credential-name}");
        description = "Where each of its units reads it";
      };
      credential = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = let units = lib.attrNames config.credentials; in
          if lib.length units == 1 then config.credentials.${lib.head units}
          else throw "secret ${config.file-name}: credential names its one unit's copy, but it has ${toString (lib.length units)}; use credentials.<unit>";
        description = "Where its one unit reads it";
      };
      path = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${secret-dirs.${config.kind}}/${config.file-name}.age";
        description = "The encrypted file, under secrets/";
      };
      file = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        default = ../secrets + "/${config.path}";
        description = "The encrypted file";
      };
    };
  });
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
  mkAppOption = { name, description, homepage, simpleicon ? null, guide ? null,
                  service ? (lib.toLower (lib.replaceStrings [ " " ] [ "-" ] name)),
                  usesStateDir ? (service != null),
                  subdomain, port, admin ? "admin", extra-groups ? [],
                  auth ? {}, cacheSubdirs ? [], stateSubdirs ? null, health ? null,
                  followsPrimary ? false, exposure ? (if followsPrimary then "mesh" else "local"),
                  clients ? [], ports ? {}, secrets ? {}, mail ? null, extraOptions ? {} }:
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
      guide = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = guide;
        description = ''
          The ${name} app's section of the services page: a <details> element,
          in which $URL, $SUBDOMAIN and $ACCESS stand for its address, its
          subdomain and the template test of whether a visitor may use it.
        '';
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
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
            options = {
              secret = lib.mkOption {
                type = lib.types.nullOr (secret { kind = "oidc"; file-name = "${name}-secret"; as = "oidc-secret"; });
                default = { };
                description = ''
                  The client's secret, in secrets/oidc/<id>-secret.age, its
                  digest beside it; null where the app keeps it elsewhere or
                  the client is public. Its credential is oidc-secret.
                '';
              };
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
          }));
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
      mail = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            sender = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "noreply";
              description = ''
                The local part it sends as through the site's Stalwart, at
                its own subdomain. No password: only its units reach the
                submission port.
              '';
            };
            smtp = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  host = lib.mkOption { type = lib.types.str; description = "The SMTP server"; };
                  port = lib.mkOption { type = lib.types.port; description = "Its submission port"; };
                  security = lib.mkOption {
                    type = lib.types.enum [ "tls" "starttls" "none" ];
                    description = "Implicit TLS, STARTTLS, or neither";
                  };
                  username = lib.mkOption { type = lib.types.str; description = "Who it signs in as"; };
                };
              });
              default = null;
              description = "Another SMTP server it sends through instead, its password the app's smtp credential";
            };
            from = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The address it sends from through another server";
            };
            units = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "The units that send, each loading the smtp credential when it has one";
            };
            reply-to = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "contact@example.org";
              description = "Where replies to its mail go, if its modules set a Reply-To";
            };
          };
          # field by field, so the site's settings may add to them
          config = lib.mapAttrs (_: lib.mkDefault) (if mail == null then { } else mail);
        });
        default = if mail == null then null else { };
        description = ''
          How the ${name} app sends mail, by one of two forms: `sender`,
          through the site's Stalwart, or `smtp` and `from`, through
          another server. Either way its modules read the connection from
          site.mail.connections.<app>.
        '';
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf (secret { prefix = id-of name; });
        default = secrets // lib.optionalAttrs (mail != null && mail ? smtp) {
          smtp = { kind = "credential"; description = "${name}'s password at ${mail.smtp.host}"; inherit (mail) units; };
        };
        description = ''
          The secrets the ${name} app holds, by name, each a file named
          ${id-of name}-<name> unless it says otherwise. Other apps reading one
          refer to it here, so where it belongs stays plain.
        '';
      };
    } // extraOptions;
  mesh = port: unit: clients: { inherit port unit clients; exposure = "mesh"; };
  local = port: unit: clients: { inherit port unit clients; };
  public = port: unit: { inherit port unit; exposure = "public"; };
}
