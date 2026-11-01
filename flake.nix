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
      site-lib = import ./site/lib.nix { inherit (nixpkgs) lib; };
      # every app's and module's metadata, which each host knows of all of them
      site-metadata = nixpkgs.lib.concatMap (root: nixpkgs.lib.concatMap (name:
          nixpkgs.lib.optional (builtins.pathExists (root + "/${name}/site.nix")) (root + "/${name}/site.nix"))
        (builtins.attrNames (builtins.readDir root))) [ ./apps ./modules ];
      # every app and module, by name
      modules = flake-utils-plus.lib.exportModules (nixpkgs.lib.concatMap (root:
        nixpkgs.lib.mapAttrsToList (name: _: root + "/${name}") (builtins.readDir root)) [ ./apps ./modules ]);
      core-modules = site-lib.site-modules [ ./apps ./modules ] ++ [ { site = import ./site.nix; } ] ++ (with modules; [
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
      ]);
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
          specialArgs = { inherit inputs site-lib; };
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
          domain = sys.config.site.domain;
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
      machine-site = name: setup: {
        server = (setup.server or { }) // { host = name; };
        apps = setup.apps or { };
      };
      # Every declared secret has its file, unless optional, and every file a declaration
      secrets-declared = let
        inherit (nixpkgs) lib;
        # the same on every host
        declared = self.nixosConfigurations.golgi.config.site.secret-files;
        files = lib.concatMap (dir: map (file: "${dir}/${file}")
          (lib.filter (lib.hasSuffix ".age") (builtins.attrNames (builtins.readDir (./secrets + "/${dir}")))))
          [ "keys" "credentials" "passwords" "oidc" ];
        problems = map (path: "secrets/${path}: declared, but there is no such file")
            (lib.filter (path: !declared.${path}.optional && !builtins.pathExists (./secrets + "/${path}"))
              (builtins.attrNames declared))
          ++ map (path: "secrets/${path}: no site.nix declares it") (lib.filter (path: !(declared ? ${path})) files);
      in nixpkgs.legacyPackages.x86_64-linux.runCommand "secrets-declared" { } (if problems == [ ] then "touch $out" else ''
        printf '%s\n' ${lib.escapeShellArgs problems} >&2
        exit 1
      '');
    in flake-utils-plus.lib.mkFlake {
      inherit self inputs modules;

      hosts = (builtins.mapAttrs
        (name: setup: {
          specialArgs = { inherit site-lib; };
          modules = core-modules ++ setup.modules ++ [ ({ config, ... }: {
            assertions = [ {
              assertion = nixpkgs.lib.sort (a: b: a < b) config.site.hosts == builtins.attrNames machines;
              message = "flake.nix builds ${toString (builtins.attrNames machines)}, but site.nix names the hosts ${toString config.site.hosts}";
            } ];
          }) {
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

      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") { inherit secrets-declared; }) inputs.deploy-rs.lib;
    };
}
