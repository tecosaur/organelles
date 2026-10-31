{ config, lib, pkgs, ... }:

# Stalwart, its sign-in through Authelia, and the mail records dns-pooler asserts. Each start
# applies the settings through stalwart-provision.nix, leaving no standing administrator.

let
  app = config.site.apps.mail;
  inherit (config.site) domain ports;
  inherit (config.site.ha) voters;
  inherit (config.site.mail) gateway oidc relay smtp2go;
  this-host = config.site.server.host;
  package = pkgs.callPackage ./packages/stalwart.nix { };
  cli = pkgs.callPackage ./packages/stalwart-cli.nix { };
  user = "stalwart";
  hostname = "${app.subdomain}.${domain}";
  inherit (config.services.ha.postgres) primary-env;
  credentials = "/run/credentials/stalwart.service";
  log-dir = "/var/log/stalwart";
  public-ports = lib.mapAttrs (_: listener: listener.port) (lib.filterAttrs (_: listener: listener.exposure == "public") app.ports);
  # Stalwart's default
  max-message-bytes = 104857600;
  addressing = import ./addressing.nix { inherit lib; } { inherit (config.site.mail) domains admins; };
  filing-script = "filing";
  dkim-domains = map (d: d.name) (lib.filter (d: d.signs) addressing.domains);
  dkim-secrets = map (name: "dkim-${name}") dkim-domains;
  dkim-selector = "stalwart";
  dkim-record = name:
    let record = ../../secrets/keys + "/dkim-${name}.txt";
    in if builtins.pathExists record then lib.removeSuffix "\n" (builtins.readFile record)
       else throw "mail: no DKIM key for ${name}; add dkim-${name}:dkim to secrets/scripts/init-keys.sh and run it";
  age-path = name: config.age.secrets.${name}.path;
  credential-files = {
    valkey-password = age-path "valkey-stalwart";
    # Sentinel takes the shared password, as the default user
    sentinel-password = age-path "valkey-ha";
    s3-secret = age-path "s3-overflow-client";
    meilisearch-key = age-path "meilisearch-stalwart";
    bunny-key = age-path "bunny-dns-key";
  } // lib.genAttrs dkim-secrets age-path
    // lib.optionalAttrs (relay != null) { relay-password = age-path "stalwart-relay"; };
  file = name: { "@type" = "File"; filePath = "${credentials}/${name}"; };
  auth-domain = lib.removePrefix "https://" oidc.issuer;
  mail-host = "${hostname}.";
  record = name: type: value: { inherit name type value; };
  mx-names = [ "@" "*" "www" ];
  # TXT data stays unquoted: each adapter splits it into strings itself
  stalwart-dkim = lib.concatLists (lib.mapAttrsToList (sending-domain: key:
    let fqdn = "${key.selector}._domainkey.${sending-domain}";
    in lib.optional (lib.hasSuffix ".${domain}" fqdn)
      (record (lib.removeSuffix ".${domain}" fqdn) "TXT" key.record))
    config.site.mail.dkim);
  # SRV ports are Stalwart's public listeners, and Caddy's for JMAP
  client-srv = lib.mapAttrsToList (name: port: record name "SRV" "0 1 ${toString port} ${mail-host}") {
    "_imaps._tcp" = 993;
    "_submissions._tcp" = 465;
    "_jmap._tcp" = 443;
  };
  settings = pkgs.writeText "stalwart-settings.ndjson" (import ./stalwart-settings.nix { inherit lib; } addressing {
    inherit domain hostname public-ports dkim-selector max-message-bytes filing-script log-dir;
    acme = { contact = "postmaster@${domain}"; bunny-key = "${credentials}/bunny-key"; };
    in-memory-store = {
      "@type" = "RedisSentinel";
      urls = lib.genAttrs (map (host: "redis://${host}.internal:${toString ports.ha-sentinel.port}") voters) (_: true);
      serviceName = "ha";
      authUsername = user;
      authSecret = file "valkey-password";
      sentinelSecret = file "sentinel-password";
    };
    blob-store = {
      "@type" = "S3";
      inherit (gateway) bucket;
      region = { "@type" = "Custom"; url = gateway.endpoint; inherit (gateway) region; };
      accessKeyId = { "@type" = "Value"; value = gateway.access-key-id; };
      secretKey = file "s3-secret";
      timeout = gateway.timeout-seconds * 1000;
    };
    search-store = {
      "@type" = "Meilisearch";
      inherit (config.site.meilisearch) url;
      httpAuth = { "@type" = "Bearer"; bearerToken = file "meilisearch-key"; };
    };
    inherit oidc;
    dkim-keys = lib.genAttrs dkim-domains (name: "${credentials}/dkim-${name}");
    http-port = app.port;
    web-ui = { bundle = "file://${package.webui}"; client-id = oidc.web-ui-client; };
    relay = if relay == null then null else {
      inherit (relay) host port username;
      secret-file = "${credentials}/relay-password";
    };
  });
  provision = import ./stalwart-provision.nix { inherit lib pkgs; } {
    inherit package cli addressing filing-script;
    http-port = app.port;
    recovery-port = app.ports.stalwart-recovery.port;
  };
  start = pkgs.writeShellApplication {
    name = "stalwart-start";
    runtimeInputs = with pkgs; [ coreutils curl jq postgresql systemd ];
    text = ''
      # What other units and hosts provide is waited for, in the unit's status, never failed on
      await() {
        local what="$1"
        shift
        "$@" && return
        echo "stalwart: waiting for $what"
        systemd-notify --status="Waiting for $what" || true
        until "$@"; do sleep 2; done
      }
      # A directory Stalwart cannot load at start stays unavailable until it restarts
      await "Authelia at ${oidc.issuer}" curl -sf -o /dev/null --max-time 5 ${oidc.issuer}/.well-known/openid-configuration
      await "postgresql-ha-role to name the HA primary" grep -qs '^HA_PRIMARY=.' ${primary-env}
      primary=$(sed -n 's/^HA_PRIMARY=//p' ${primary-env})
      # The leader creates the roles its own generation lists, so a host deployed before it waits
      has_database() { PGCONNECT_TIMEOUT=5 psql -w -h "$primary.internal" -p ${toString ports.ha-postgres.port} -d ${user} -Atqc 'SELECT 1' >/dev/null 2>&1; }
      await "$primary to create the ${user} database, as it does once it runs this generation" has_database
      jq -n --arg host "$primary.internal" '{
        "@type": "PostgreSql", host: $host, port: ${toString ports.ha-postgres.port},
        database: "${user}", authUsername: "${user}", authSecret: {"@type": "None"}
      }' >"$RUNTIME_DIRECTORY/config.json"
      # The previous generation's settings, which the provisioner retracts against until it has its own record
      previous_settings() {
        local current link start
        current=$(readlink -f /run/current-system)
        for link in $(printf '%s\n' /nix/var/nix/profiles/system-*-link | sort -rV); do
          [ "$(readlink -f "$link")" != "$current" ] || continue
          start=$(sed -n 's/^ExecStart=//p' "$link/etc/systemd/system/stalwart.service" 2>/dev/null) || return 0
          grep -so '/nix/store/[a-z0-9]*-stalwart-settings\.ndjson' "$start" | head -1 || true
          return 0
        done
      }
      ${lib.getExe provision} ${settings} "$(previous_settings)"
      systemd-notify --status= || true
      exec ${lib.getExe package} --config "$RUNTIME_DIRECTORY/config.json"
    '';
  };
in {
  config = lib.mkMerge [ {
    site.mail.dkim = lib.genAttrs dkim-domains (name: { selector = dkim-selector; record = dkim-record name; });
    site.meilisearch.keys.stalwart = [ "st_*" ];
    site.dns.records =
      map (name: record name "MX" "10 ${mail-host}") mx-names
      ++ [
        (record "@" "TXT" "v=spf1 include:spf.smtp2go.com ?all")
        (record "_dmarc" "TXT" "v=DMARC1; p=none")
      ]
      ++ stalwart-dkim
      ++ client-srv
      ++ smtp2go.records;
  } (lib.mkIf config.site.ha.may-lead {
    assertions = [
      {
        assertion = max-message-bytes <= gateway.max-object-bytes;
        message = "mail: Stalwart takes messages of ${toString max-message-bytes} bytes, more than the gateway's ${toString gateway.max-object-bytes}";
      }
      {
        assertion = config.site.mail.domains ? ${domain};
        message = "mail: Stalwart's default domain ${domain} is not in site.mail.domains; add site.mail.domains.\"${domain}\"";
      }
      {
        assertion = config.services.authelia.instances.main.enable or false;
        message = "mail: ${config.site.server.host} may run Stalwart but not Authelia, which Stalwart signs in through; import the auth module there";
      }
    ];
    services.authelia.instances.main.settings = {
      # Stalwart is never granted email, so without the claim it refuses the sign-in
      definitions.user_attributes.${oidc.account-claim}.expression = addressing.sign-in.account;
      identity_providers.oidc = {
        scopes.${oidc.account-claim}.claims = [ oidc.account-claim ];
        claims_policies.${oidc.claims-policy} = {
          custom_claims.${oidc.account-claim} = { };
          # name too, so Stalwart finds every claim it wants in the token and never asks userinfo
          access_token = [ oidc.account-claim "name" ];
        };
        # Every sign-in that yields a refresh token asks for consent, so Bulwark's lasts
        lifespans.custom.${oidc.lifespan}.refresh_token = "30d";
        authorization_policies.${oidc.authorization-policy} = {
          default_policy = "deny";
          # An empty subject would admit everyone
          rules = lib.optional (addressing.sign-in.subjects != [ ]) { policy = "two_factor"; subject = addressing.sign-in.subjects; };
        };
      };
    };
    # Every OIDC app on this host, not only mail, then fetches discovery and JWKS from the local Authelia
    networking.hosts = {
      "127.0.0.1" = [ auth-domain ];
      "::1" = [ auth-domain ];
    };
    site.apps.mail.enabled = true;
    site.unfree = [ "stalwart" ];
    age.secrets = {
      meilisearch-stalwart.file = ../../secrets/keys/meilisearch-stalwart.age;
    } // lib.genAttrs dkim-secrets (name: { file = ../../secrets/keys + "/${name}.age"; })
      // lib.optionalAttrs (relay != null) { stalwart-relay.file = relay.credential-file; };
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = { };
    services.ha.postgres = {
      databases = [ user ];
      track-primary = [ "stalwart" ];
    };
    environment.systemPackages = [ cli ];
    # Stalwart rotates its log daily but never deletes one
    systemd.tmpfiles.rules = [ "e ${log-dir} - - - 30d" ];
    systemd.services.stalwart = {
      description = "Stalwart mail server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "authelia-main.service" "valkey-ha.service" "s3-overflow.service" ];
      environment = {
        STALWART_PUBLIC_URL = "https://${hostname}";
        STALWART_ROLE = if this-host == config.site.ha.primary then "scheduler" else "worker";
        # Default roles are made once, at the first start, so each start gives them the permissions
        # releases since have added
        STALWART_UPDATE_ROLE_PERMISSIONS = "true";
      };
      sandboxed = true;
      serviceConfig = {
        # Started once exec'd, so waits never hold a deploy
        Type = "exec";
        # So the start script can report what it waits for
        NotifyAccess = "all";
        User = user;
        Group = user;
        ExecStart = lib.getExe start;
        KillSignal = "SIGINT";
        Restart = "always";
        RestartSec = "10s";
        LimitNOFILE = 65536;
        LoadCredential = lib.mapAttrsToList (name: source: "${name}:${source}") credential-files;
        RuntimeDirectory = "stalwart";
        RuntimeDirectoryMode = "0700";
        CacheDirectory = "stalwart";
        CacheDirectoryMode = "0700";
        # The settings last applied, against which the next start retracts
        StateDirectory = "stalwart";
        StateDirectoryMode = "0700";
        LogsDirectory = "stalwart";
        LogsDirectoryMode = "0700";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
      # Unmet prerequisites are retried for as long as they last
      startLimitIntervalSec = 0;
    };
    site.status.units = lib.mapAttrsToList (name: port: {
      id = "stalwart-${name}";
      name = "Mail, ${name} on ${toString port}";
      unit = "stalwart.service";
      command = [ (lib.getExe pkgs.netcat-openbsd) "-z" "-w" "3" "127.0.0.1" (toString port) ];
    }) public-ports;
  }) ];
}
