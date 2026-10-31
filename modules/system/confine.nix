{ config, lib, pkgs, ... }:

# Which units may reach which listeners. Every local or mesh TCP listener in site.listeners
# names its clients, each a unit with the hosts it runs on; every host derives from that both
# its ingress (which hosts may connect over wg0) and its egress (which of its own units may
# dial). Egress matches each client unit's slice, not the unit: nft resolves a cgroup path
# once, at load, and a restarted unit gets a new cgroup, while its slice lasts.

let
  cfg = config.site.confine;
  this-host = config.site.server.host;
  address = host: config.site.mesh.addresses.${host};
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
  ingress-rule = listener: let
    hosts = lib.unique (lib.concatLists (lib.attrValues listener.clients));
  in lib.optionalString (listener.exposure == "mesh" && lib.elem this-host listener.hosts) ''
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
  '' + lib.optionalString (lib.elem this-host listener.hosts) ''
    ct state new fib daddr type local ${to-port}
  '';
  ruleset = pkgs.writeText "confine.nft" ''
    table inet confine
    delete table inet confine
    table inet confine {
      ${lib.concatMapStrings (listener: ''
        counter ${counter "in" listener.name} { }
        counter ${counter "out" listener.name} { }
      '') confined}
      chain refuse {
        limit rate 6/minute burst 5 packets log prefix "confine: " flags skuid
        ${lib.optionalString (cfg.mode == "enforce") "reject with tcp reset"}
      }
      # ahead of nixos-fw, whose wg0 openings would accept any peer
      chain input {
        type filter hook input priority filter - 1; policy accept;
        ${lib.concatMapStrings ingress-rule confined}
      }
      chain output {
        type filter hook output priority filter; policy accept;
        ${lib.concatMapStrings egress-rule confined}
      }
    }
  '';
in {
  options.site.confine.mode = lib.mkOption {
    type = lib.types.enum [ "off" "log" "enforce" ];
    default = "log";
    description = ''
      What happens to a connection to a listener from a unit or host not among
      its clients: nothing, a counted and rate-limited log line, or a reset.
      Set per host, so enforcement can roll out one host at a time.
    '';
  };

  config = lib.mkIf (cfg.mode != "off" && confined != [ ]) {
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
  };
}
