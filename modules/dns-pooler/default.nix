{ config, lib, pkgs, inputs, ... }:

# dns-pooler keeps the zone matching what each host serves. Every host's
# configuration carries the whole site: each name a host's Caddy serves,
# the apex and wildcard included, becomes a service. A name one host serves
# is direct, flattened to that host's own addresses; a name several serve
# is a pool of its own name, which Bunny steers to the nearest healthy one.
# Each is checked through its app where site.apps knows one, and through
# Caddy otherwise. Every address is detected at runtime rather than declared.

let
  inherit (config.site) domain hosts dns;
  this-host = config.site.server.host;
  dns-pooler-pkg = pkgs.callPackage ./package.nix { };
  toml = pkgs.formats.toml { };
  peer-port = config.site.ports.dns-pooler-peer.port;
  # /status for the local monitor, unauthenticated, so loopback only
  status-port = config.site.ports.dns-pooler-status.port;
  # systemd places a LoadCredential secret at this fixed per-unit path
  credential-path = "/run/credentials/dns-pooler.service/provider";
  mesh-endpoint = host: "[${config.site.mesh.addresses.${host}}]:${toString peer-port}";
  enabled-apps = lib.filter (app: app.enabled && app.host != null)
    (lib.attrValues config.site.apps);
  # each served name with the hosts serving it
  servers = lib.zipAttrs (lib.mapAttrsToList
    (host: names: lib.genAttrs names (_: host)) dns.served);
  pooled-names = lib.attrNames (lib.filterAttrs (_: hosts: lib.length hosts > 1) servers);
  # A served name's checks come from the app at that subdomain; names no app
  # accounts for (the apex, short links, served repositories) are Caddy's,
  # as are those of apps every Caddy proxies to the primary.
  service-for = name: hosts:
    let app = lib.findFirst (a: lib.elem a.host hosts && a.subdomain == name) null enabled-apps;
    in { inherit name hosts; }
       // (if lib.elem name pooled-names then { pool = name; } else { direct = true; })
       // (if app == null || app.followsPrimary then { service = "caddy.service"; } else
         lib.optionalAttrs (app.service != null) {
           service = "${app.service}.service";
         }
         // lib.optionalAttrs (app.health != null && app.health.path != null) {
           http = lib.filterAttrs (_: v: v != null) {
             inherit (app) port;
             inherit (app.health) path status body;
           };
         }
         // lib.optionalAttrs (app.health != null && app.health.ports != [ ]) {
           port = map (check: { port = app.ports.${check.listener}.port; inherit (check) tls; }) app.health.ports;
         });
  settings = {
    host = this-host;
    # Every host deployed from one commit agrees, and a later commit ranks
    # higher, which is what orders the writer through a rollout.
    generation = inputs.self.lastModified;
    zone = domain;
    host_domain = dns.host-domain;
    public = [ "auto" ];
    # Every name is Caddy's to present a certificate for, so a host serving
    # one without (its ACME challenge failing, say) is withdrawn from it.
    health.tls = true;
    inherit (dns) ignore;
    provider = {
      name = "bunny";
      credential_file = credential-path;
      monitoring.type = "ping";
    };
    peers = {
      listen = mesh-endpoint this-host;
      status_listen = "127.0.0.1:${toString status-port}";
      wg_interface = "wg0";
    };
    peer = lib.genAttrs (lib.remove this-host hosts)
      (host: { private = mesh-endpoint host; public = [ "auto" ]; });
    pool = lib.genAttrs pooled-names (_: { });
    dynamic = lib.mapAttrsToList service-for servers;
    static = dns.records;
  };
  # The credential is a runtime secret, so check only warns it cannot read
  # it; every structural rejection fails the build instead of the deploy.
  config-file = pkgs.runCommand "dns-pooler.toml" { nativeBuildInputs = [ dns-pooler-pkg ]; } ''
    dns-pooler -config ${toml.generate "dns-pooler.toml" settings} check
    cp ${toml.generate "dns-pooler.toml" settings} $out
  '';
  # A fixed path, so a changed configuration reloads rather than changing the unit
  config-path = "/etc/dns-pooler/config.toml";
in {
  site.status.units = [ {
    id = "dns-pooler";
    name = "dns-pooler";
    unit = "dns-pooler.service";
    # Running is not working: unable to write the zone, it leaves DNS as it was, and failover with it
    command = [ (lib.getExe (pkgs.writeShellApplication {
      name = "dns-pooler-health";
      runtimeInputs = with pkgs; [ curl jq ];
      text = ''
        status=$(curl -sf --max-time 3 http://127.0.0.1:${toString status-port}/status) || { echo "its status is unavailable"; exit 1; }
        problem=$(jq -r 'if .stranded then "it cannot write the zone"
          elif (.conflicts // []) != [] then "addresses claimed by two hosts: " + (.conflicts | join(", "))
          else empty end' <<<"$status")
        [ -z "$problem" ] || { echo "$problem"; exit 1; }
      '';
    })) ];
  } ];

  # shared with Caddy, which answers ACME DNS challenges with it
  age.secrets.bunny-dns-key.file = ../../secrets/credentials/bunny-dns-key.age;

  environment.etc."dns-pooler/config.toml".source = config-file;

  systemd.services.dns-pooler = {
    description = "dns-pooler DNS pool reconciliation";
    reloadTriggers = [ config-file ];
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    # the mesh address must exist before the peer listener can bind it
    after = [ "network-online.target" "systemd-networkd.service" ];
    # `wg show` for mesh receive counters, `systemctl show` for unit health
    path = [ pkgs.wireguard-tools config.systemd.package ];
    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = "${lib.getExe dns-pooler-pkg} -config ${config-path} run";
      # Applies what it can live, re-executing in place for the rest
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      # Above the longest blocking step (10s) and, with the 10s request
      # deadline, under dead_after (30s)
      WatchdogSec = 15;
      # A retired or stopped daemon exits cleanly and must stay down; a crash
      # or a watchdog kill restarts it.
      Restart = "on-failure";
      RestartSec = "5s";
      LoadCredential = [ "provider:${config.age.secrets.bunny-dns-key.path}" ];
      DynamicUser = true;
      # reading WireGuard counters needs CAP_NET_ADMIN, and nothing else does
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      UMask = "0077";
    };
  };
}
