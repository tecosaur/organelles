{ config, lib, pkgs, site-lib, ... }:

# What the site listens on, and who may reach it: the firewall opens exactly the declared
# listeners, and confinement admits only their clients. Egress matches each client's slice,
# not its unit: nft resolves a cgroup once, and a restarted unit gets a new one.

let
  inherit (site-lib) listener;
  inherit (config.site) reach;
  this-host = config.site.server.host;
  address = host: config.site.mesh.addresses.${host};
  # A listener's clients as each unit with the hosts it runs on; a bare list
  # names units on the listener's own hosts
  client-hosts = hosts: clients: if lib.isList clients then lib.genAttrs clients (_: hosts) else clients;
  merge-clients = lib.zipAttrsWith (_: hosts: lib.unique (lib.concatLists hosts));
  on = units: hosts: lib.genAttrs units (_: hosts);
  all-listeners = let
    of-app = name: app: let
      probed = if app.health == null then [ ] else map (check: check.listener) app.health.ports;
      main = {
        inherit name;
        inherit (app) port exposure hosts;
        unit = app.service;
        protocols = [ "tcp" ];
        clients = merge-clients ([
          (on reach.proxies (if app.exposure == "mesh" then config.site.hosts else app.hosts))
          (client-hosts app.hosts app.clients)
        ] ++ lib.optional (app.health != null && app.health.path != null) (on reach.probes app.hosts));
      };
      extra = lib.mapAttrsToList (listener-name: listener: let
        hosts = if listener.hosts == null then app.hosts else listener.hosts;
      in listener // {
        name = "${name}-${listener-name}";
        inherit hosts;
        clients = merge-clients ([ (client-hosts hosts listener.clients) ]
          ++ lib.optional (lib.elem listener-name probed) (on reach.probes hosts));
      }) app.ports;
    in [ main ] ++ extra;
  in lib.concatLists (lib.mapAttrsToList of-app (lib.filterAttrs (_: app: app.enabled) config.site.apps))
    ++ lib.mapAttrsToList (name: listener: let
      # unfilled outside the flake's final evaluation
      hosts = if listener.hosts == null then [ ] else listener.hosts;
    in listener // { inherit name hosts; clients = client-hosts hosts listener.clients; }) config.site.ports;
  listeners-here = lib.filter (listener: lib.elem this-host listener.hosts) config.site.listeners;

  # The firewall
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
  contested-ports = lib.filterAttrs (_: claimants: lib.length claimants > 1)
    (lib.groupBy (listener: toString listener.port) listeners-here);

  # Confinement
  mode = config.site.confine.mode;
  # a dash in a slice name nests it, so each unit's slice sits directly under confine.slice
  slice-of = unit: "confine-${lib.replaceStrings [ "-" ] [ "_" ] unit}";
  cgroup-of = unit: "confine.slice/${slice-of unit}.slice";
  # nft object names take no dashes
  counter = direction: name: "${direction}_${lib.replaceStrings [ "-" ] [ "_" ] name}";
  set = items: "{ ${lib.concatStringsSep ", " items} }";
  # anyone may reach a public listener, and nft's socket match sees TCP alone
  confined = lib.filter (listener: listener.exposure != "public" && lib.elem "tcp" listener.protocols)
    config.site.listeners;
  units-here = clients: lib.attrNames (lib.filterAttrs (_: hosts: lib.elem this-host hosts) clients);
  local-clients = lib.unique (lib.concatMap (listener: units-here listener.clients) confined);
  serves = listener: lib.elem this-host listener.hosts;
  ruled = lib.filter (listener: serves listener || (listener.exposure == "mesh" && listener.hosts != [ ])) confined;
  ingress-rule = listener: let
    hosts = lib.unique (lib.concatLists (lib.attrValues listener.clients));
  in lib.optionalString (listener.exposure == "mesh" && serves listener) ''
    ct state new iifname "wg0" tcp dport ${toString listener.port} ${lib.optionalString (hosts != [ ])
      "ip6 saddr != ${set (map address hosts)}"} counter name ${counter "in" listener.name} jump refuse
  '';
  egress-rule = listener: let
    allowed = units-here listener.clients;
    unit-match = lib.optionalString (allowed != [ ])
      "socket cgroupv2 level 2 != ${set (map (unit: ''"${cgroup-of unit}"'') allowed)}";
    to-port = "tcp dport ${toString listener.port} ${unit-match} counter name ${counter "out" listener.name} jump refuse";
    remote-servers = lib.remove this-host listener.hosts;
  in lib.optionalString (listener.exposure == "mesh" && remote-servers != [ ]) ''
    ct state new ip6 daddr ${set (map address remote-servers)} ${to-port}
  '' + lib.optionalString (serves listener) ''
    ct state new fib daddr type local ${to-port}
  '';
  ruleset = pkgs.writeText "confine.nft" ''
    table inet confine
    delete table inet confine
    table inet confine {
      ${lib.concatMapStrings (listener: ''
        ${lib.optionalString (listener.exposure == "mesh" && serves listener) "counter ${counter "in" listener.name} { }"}
        counter ${counter "out" listener.name} { }
      '') ruled}
      chain refuse {
        limit rate 6/minute burst 5 packets log prefix "confine: " flags skuid
        ${lib.optionalString (mode == "enforce") "reject with tcp reset"}
      }
      # ahead of nixos-fw, whose wg0 openings would accept any peer
      chain input {
        type filter hook input priority filter - 1; policy accept;
        ${lib.concatMapStrings ingress-rule ruled}
      }
      chain output {
        type filter hook output priority filter; policy accept;
        ${lib.concatMapStrings egress-rule ruled}
      }
    }
  '';
in {
  options.site = {
    reach = {
      proxies = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "caddy" ];
        description = ''
          Units that proxy to every app's main listener: from every host when
          it is on the mesh, else from the hosts the app runs on.
        '';
      };
      probes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "dns-pooler" ];
        description = ''
          Units that check every app's health, from the hosts it runs on: its
          main listener given a health path, and the listeners its health
          check names.
        '';
      };
    };
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
    confine.mode = lib.mkOption {
      type = lib.types.enum [ "off" "log" "enforce" ];
      default = "log";
      description = ''
        What happens to a connection to a listener from a unit or host not among
        its clients: nothing, a counted and rate-limited log line, or a reset.
        Set per host, so enforcement can roll out one host at a time.
      '';
    };
  };

  config = lib.mkMerge [ {
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
    } {
      assertion = contested-ports == { };
      message = "site: ${lib.concatStringsSep "; " (lib.mapAttrsToList (port: claimants:
        "port ${port} claimed by ${lib.concatMapStringsSep ", " (listener: listener.name) claimants}") contested-ports)} "
        + "on ${this-host}; give one of them a free port in its site.nix";
    } ];
  } (lib.mkIf (mode != "off" && confined != [ ]) {
    assertions = map (unit: {
      assertion = config.systemd.services ? ${unit};
      message = "site.confine: ${unit} is named as a client on ${this-host}, which runs no such service";
    }) local-clients;

    systemd.slices = lib.listToAttrs (map (unit: lib.nameValuePair (slice-of unit) {
      description = "Confinement of ${unit}";
      # active from boot, so the ruleset finds its cgroup at every load
      wantedBy = [ "multi-user.target" ];
    }) local-clients);

    systemd.services = lib.listToAttrs (map (unit: lib.nameValuePair unit {
      # over any slice its module groups it in, which nft could not follow across restarts
      serviceConfig.Slice = lib.mkForce "${slice-of unit}.slice";
    }) local-clients) // {
      # Apart from the main firewall, so a cgroup that fails to resolve costs only this table
      confine = {
        description = "Confine units to the listeners they may reach";
        wantedBy = [ "multi-user.target" ];
        wants = map (unit: "${slice-of unit}.slice") local-clients;
        after = [ "nftables.service" ] ++ map (unit: "${slice-of unit}.slice") local-clients;
        reloadIfChanged = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${ruleset}";
          ExecReload = "${pkgs.nftables}/bin/nft -f ${ruleset}";
          ExecStop = "${pkgs.nftables}/bin/nft delete table inet confine";
        };
      };
    };

    system.checks = [ (pkgs.runCommand "confine-ruleset-check" { nativeBuildInputs = [ pkgs.nftables ]; } ''
      # checked as nixos-fw is, against a userspace kernel, which has no cgroups to resolve
      sed 's/socket cgroupv2 level 2 != {[^}]*}//' ${ruleset} > ruleset.nft
      export NIX_REDIRECTS=${lib.escapeShellArg (lib.concatStringsSep ":"
        (lib.mapAttrsToList (n: v: "${n}=${v}") config.networking.nftables.checkRulesetRedirects))}
      LD_PRELOAD="${pkgs.libredirect}/lib/libredirect.so ${pkgs.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
        nft --check --file ruleset.nft
      touch $out
    '') ];
  }) ];
}
