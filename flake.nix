{
  description = "Deployable system configurations";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    flake-utils-plus.url = github:gytis-ivaskevicius/flake-utils-plus;
    agenix.url = "github:ryantm/agenix";
    # PR 35 lists Jellyfin 12.3 and 12.4; back to the default branch once merged
    declarative-jellyfin.url = "github:Sveske-Juice/declarative-jellyfin/pull/35/head";
    declarative-jellyfin.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs = {
      url = github:serokell/deploy-rs;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig.sandbox = "relaxed";

  outputs = inputs@{ self, nixpkgs, flake-utils-plus, agenix, declarative-jellyfin, ... }:
    let
      site-config = import ./site;
      # every app and module, by name
      modules = flake-utils-plus.lib.exportModules (nixpkgs.lib.concatMap (root:
        nixpkgs.lib.mapAttrsToList (name: _: root + "/${name}") (builtins.readDir root)) [ ./apps ./modules ]);
      core-modules = with modules; [
        agenix.nixosModules.default
        beszel-agent
        caddy
        crowdsec
        dns-pooler
        high-availability
        mail
        meilisearch
        site-config
        status
        system
        tailscale
        vaultwarden
        wireguard-mesh
        zsh
      ];
      machines = {
        golgi = {
          server = {
            authoritative = true;
            ipv6 = "2a01:4ff:f0:cc83";
          };
          modules = with modules; [
            authelia
            lldap
            beszel-hub
            fava
            hardware-hetzner
            headscale
            ntfy
            # mealie
            memos
            microbin
            rustical
            site-root
            syncthing
          ];
        };
        centrosome = {
          modules = with modules; [ hardware-oracle ];
        };
        nucleus = {
          apps.llm.proxy = [ "tranquillity.lan:5521" ];
          modules = with modules; [
            authelia
            lldap
            data-mounts
            declarative-jellyfin.nixosModules.default
            hardware-nas
            home-assistant
            dawarich
            forgejo
            immich
            llm
            lyrion
            paperless
            scrobbler
            scrutiny
            sftpgo
            site-root
            speedtest
            storyteller
            jellyfin
            transmission
            tandoor
            trek
            warracker
          ];
        };
      };
      # Every machine evaluated with its real site settings, short of what is
      # computed from all of them, for the facts one host's configuration
      # needs about the others.
      machine-systems = nixpkgs.lib.mapAttrs
        (name: setup: (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [ flake-utils-plus.nixosModules.autoGenFromInputs ] ++
                    core-modules ++ setup.modules ++
                    [ { site = machine-site name setup; } ];
        }))
        machines;
      # every machine each app is enabled on, in machine order
      global-app-hosts = nixpkgs.lib.zipAttrs (nixpkgs.lib.mapAttrsToList (machine: sys:
        nixpkgs.lib.mapAttrs (_: _: machine)
          (nixpkgs.lib.filterAttrs (_: conf: conf.enabled) sys.config.site.apps))
        machine-systems);
      # every machine running each site.ports listener's unit, for those naming no hosts
      global-port-hosts = nixpkgs.lib.mapAttrs (_: listener:
        nixpkgs.lib.filter (machine:
          let services = machine-systems.${machine}.config.systemd.services;
          in services ? ${listener.unit} && services.${listener.unit}.enable)
          (builtins.attrNames machines))
        (nixpkgs.lib.filterAttrs (_: listener: listener.hosts == null)
          (builtins.head (builtins.attrValues machine-systems)).config.site.ports);
      global-enabled-apps = nixpkgs.lib.concatMapAttrs (machine: sys:
        (nixpkgs.lib.foldlAttrs
          (acc: app: conf:
            if conf.enabled then
              acc // { "${app}" = {
                         enabled = true;
                         host = machine;
                         hosts = global-app-hosts.${app};
                         serviceConfig = if conf.service == null then { } else
                           sys.config.systemd.services."${conf.service}".serviceConfig;
                       }; }
            else acc)
          { }
          sys.config.site.apps))
        machine-systems;
      global-status-units = nixpkgs.lib.mapAttrs (_: sys: sys.config.site.status.units) machine-systems;
      # The names each machine's Caddy serves, relative to the domain ("@" the
      # apex): a virtual host key may list several addresses, with a scheme or
      # port, and only those under the site domain are ours.
      global-served-names = nixpkgs.lib.mapAttrs (_: sys:
        let
          inherit (nixpkgs) lib;
          domain = site-setup.domain;
          relative = address:
            let host = lib.head (lib.splitString ":"
                  (lib.removePrefix "https://" (lib.removePrefix "http://" address)));
            in if host == domain then [ "@" ]
               else lib.optional (lib.hasSuffix ".${domain}" host) (lib.removeSuffix ".${domain}" host);
          addresses = key: lib.filter (a: a != "")
            (lib.splitString " " (lib.replaceStrings [ "," ] [ " " ] key));
        in lib.unique (lib.concatMap (key: lib.concatMap relative (addresses key))
          (lib.attrNames sys.config.services.caddy.virtualHosts)))
        machine-systems;
      # One machine's site settings, everything but what is computed across
      # machines (global-enabled-apps, dns.served, status.fleet-units).
      machine-site = name: setup: nixpkgs.lib.recursiveUpdate site-setup {
        hosts = builtins.attrNames machines;
        server = (setup.server or { }) // { host = name; };
        apps = nixpkgs.lib.recursiveUpdate site-setup.apps (setup.apps or { });
      };
      site-setup = {
        domain = "tecosaur.net";
        ha.preference = [ "nucleus" "golgi" ];
        meilisearch.host = "nucleus";
        # mail's records are apps/mail/stalwart.nix's
        dns.records = [
          { name = "ssh"; type = "CNAME"; value = "golgi.hosts.tecosaur.net."; }
        ];
        server.admin = {
          hashedPassword = "$6$ET8BLqODvw77VOmI$oun2gILUqBr/3WonH2FO1L.myMIM80KeyO5W1GrYhJTo./jk7XcG8B3vEEcbpfx3R9h.sR0VV187/MgnsnouB1";
          authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZZqcJOLdN+QFHKyW8ST2zz750+8TdvO9IT5geXpQVt tec@tranquillity" ];
        };
        email = {
          server = "smtp.fastmail.com";
          username = "tec@tecosaur.net";
        };
        mail = {
          domains."tecosaur.net" = {
            users = [ "tec" ];
            addresses = [ "{user}@{domain}" ];
            filing = "{location}@{user}.{domain}";
            catch-all = "tec";
            catch-subdomains = "tec";
          };
          admins = [ "tec" ];
          # Bodies live on nucleus's bulk volume, and spill to the light nodes while it is down
          storage = {
            primary = { nucleus = 1000000000000; };
            overflow = { golgi = 10000000000; centrosome = 10000000000; };
            overflow-quota-bytes = 2000000000;
            cache-bytes = { golgi = 4000000000; };
          };
          smtp2go.records = [
            { name = "mailbounces"; type = "CNAME"; value = "return.smtp2go.net."; }
            { name = "s766060._domainkey"; type = "CNAME"; value = "dkim.smtp2go.net."; }
            { name = "mailtrack"; type = "CNAME"; value = "track.smtp2go.net."; }
          ];
          relay = {
            host = "mail-au.smtp2go.com";
            port = 465;
            username = "stalwart.tecosaur.net";
            credential-file = ./secrets/credentials/smtp2go.age;
          };
        };
        accent = {
          primary = "#239a58";
          secondary = "#67bc85";
        };
        apps = {
          beszel.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL6RP5omIbCzQsC/NizUg56JgpgMdl0/VXmCAE0VyJlq";
          dawarich.groups = { primary = "timeline"; extra = [ "family" ]; };
          mealie.subdomain = "food";
          memos.groups.extra = [ "family" ];
          microbin = {
            title = "μPaste";
            subdomain = "pastes";
            short-subdomain = "p";
            groups.primary = "paste";
          };
          forgejo = {
            groups.primary = "forge";
            site-name = "Code by TEC";
            site-description = "The personal Forgejo instance of TEC";
            qa-captcha = {
              enabled = true;
              questions = [
                "What is my first name?"
                "What is the thing I use as my avatar?"
                "What is the mononym I often go by online?"
                "What community do you know me from?"
              ];
              answers = [
                "timothy"
                "tec"
                "tree"
                "tecosaur"
                "julia"
                "julialang"
                "emacs"
                "org"
                "doom"
              ];
            };
            default-user-redirect = "tec";
            served-repositories = [
              {
                repo = "tec/this-month-in-org";
                rev = "html";
                subdomain = "blog";
                path = "tmio";
              }
            ];
          };
          home-assistant.subdomain = "doonan";
          paperless.groups.extra = [ "family" ];
          rustical.groups = { primary = "caldav"; extra = [ "family" ]; };
          sftpgo.groups.extra = [ "family" ];
          storyteller.groups.extra = [ "family" ];
          tandoor.groups.extra = [ "family" ];
          immich.groups.extra = [ "family" ];
          jellyfin.groups.extra = [ "family" ];
          koito = {
            title = "Listens";
            groups.primary = "listens";
          };
          multi-scrobbler = {
            jellyfin-user = "tec";
            listenbrainz-user = "tecosaur";
          };
          warracker.groups.extra = [ "family" ];
        };
      };
    in flake-utils-plus.lib.mkFlake {
      inherit self inputs modules;

      hosts = (builtins.mapAttrs
        (name: setup: {
          modules = core-modules ++ setup.modules ++ [{
            site = nixpkgs.lib.recursiveUpdate (machine-site name setup) {
              apps = nixpkgs.lib.recursiveUpdate global-enabled-apps
                (machine-site name setup).apps;
              dns.served = global-served-names;
              status.fleet-units = global-status-units;
              ports = nixpkgs.lib.mapAttrs (_: hosts: { inherit hosts; }) global-port-hosts;
            };
          }];
        })
        machines);

      deploy.nodes = (builtins.mapAttrs
        (name: _: {
          hostname = with self.nixosConfigurations.${name}.config.site;
            "${name}.${dns.host-domain}.${domain}";
          fastConnection = false;
          profiles.system = {
            sshUser = "admin";
            sshOpts = [ "-S" "none" ];
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."${name}";
            user = "root";
          };
        })
        machines);

      outputsBuilder = (channels: {
        devShells.default = channels.nixpkgs.mkShell {
          name = "deploy";
          buildInputs = with channels.nixpkgs; [
            nixVersions.latest
            inputs.deploy-rs.packages.${system}.default
          ];
        };
      });

      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
    };
}
