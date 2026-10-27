{ config, lib }:

# The status page's single source: every row's group and name, and each
# host's gatus-aggregator plan, derived from the site. Gatus's
# configuration and every host's plan come from here, so they cannot
# disagree about a row. Gatus sorts groups by name: "Hosts", then
# "Services", then each "Services on <host>"; the page's own machinery
# sits with the host running Gatus.

let
  inherit (config.site) domain hosts dns;
  gatus = config.site.apps.gatus;
  # Gatus reads every file here: the generated configuration, linked in,
  # and the announcement the aggregator keeps beside it
  config-dir = "/var/lib/gatus/config";
  # each reporter's board of planned transitions, on the mesh
  conditions-port = 9435;
  # dns-pooler.nix's loopback status listener
  dns-pooler-status = "http://127.0.0.1:9434/status";
  # Alerts go to a secret topic on ntfy.sh: the site's own ntfy runs on one
  # host and refuses anonymous publishing, and an alert about that host
  # must still arrive.
  alert-url = "https://ntfy.sh";
  # unchanged rows are pushed every minute; three minutes of silence is real
  default-heartbeat = 180;
  # apps with something to observe, wherever they run
  apps = lib.sort (a: b: a.name < b.name) (lib.filter
    (app: app.enabled && app.hosts != [ ] && (app.service != null || app.health != null))
    (lib.mapAttrsToList (id: app: app // { inherit id; }) config.site.apps));
  # an app is public where its hosts' Caddy serves its subdomain
  is-public = app: lib.any (host: lib.elem app.subdomain (dns.served.${host} or [ ])) app.hosts;
  grace = app: if app.health == null then null else app.health.startupGrace;
  units = lib.concatMap (host: map (unit: unit // { inherit host; }) (config.site.status.fleet-units.${host} or [ ])) hosts;
  local-group = host: "Services on ${host}";
  # where the page's own machinery is shown: the host running Gatus
  gatus-group = local-group config.site.ha.primary;
  rows =
    [ { group = gatus-group; name = "Alert aggregator"; role = "alerting"; } ]
    ++ map (host: { group = "Hosts"; name = host; role = "host"; inherit host; }) hosts
    ++ lib.concatMap (app:
      lib.optional (is-public app) { group = "Services"; name = app.name; role = "service"; app = app.id; }
      ++ map (host: {
        group = local-group host; name = app.name; role = "local"; app = app.id; inherit host;
        # a starting run pushes nothing, so its silence must outlast its grace
        heartbeat = if grace app == null then default-heartbeat else lib.max default-heartbeat (grace app + 60);
      }) app.hosts) apps
    ++ map (unit: { group = local-group unit.host; inherit (unit) name host; role = "unit"; unit = unit.id; }) units;
  plan-app = app: lib.filterAttrs (_: v: v != null) {
    inherit (app) id name hosts port;
    public_name = if is-public app then "${app.subdomain}.${domain}" else null;
    unit = if app.service == null then null else "${app.service}.service";
    health = if app.health == null then null else lib.filterAttrs (_: v: v != null) {
      inherit (app.health) path status body;
    };
    startup_grace_seconds = grace app;
  };
  plan-unit = unit: lib.filterAttrs (_: v: v != null && v != [ ]) {
    inherit (unit) id name host kind unit command;
  };
in {
  inherit alert-url conditions-port config-dir gatus-group rows;

  # Gatus's external endpoints, one per row
  external-endpoints = map (row: {
    inherit (row) group name;
    token = "\${GATUS_PUSH_TOKEN}";
    heartbeat.interval = "${toString (row.heartbeat or default-heartbeat)}s";
  } // lib.optionalAttrs (row.role == "alerting") {
    # the one native alert: the aggregator that sends every other has stopped
    alerts = [ {
      type = "ntfy";
      failure-threshold = 1;
      success-threshold = 1;
      send-on-resolved = true;
      description = "the status aggregator has stopped, so no other alerts are being sent";
    } ];
  }) rows;

  # this host's gatus-aggregator plan
  plan = {
    host = config.site.server.host;
    inherit hosts;
    host_domain = "${dns.host-domain}.${domain}";
    gatus = {
      endpoints = lib.genAttrs hosts (host: "http://${host}.internal:${toString gatus.port}");
      local = "http://127.0.0.1:${toString gatus.port}";
      token_file = "push";
    } // lib.optionalAttrs (config.site.server.host == config.site.ha.primary) {
      announcements_file = "${config-dir}/50-announcement.yaml";
    };
    dns_pooler_status = dns-pooler-status;
    conditions = {
      listen = "[::]:${toString conditions-port}";
      peers = lib.genAttrs (lib.remove config.site.server.host hosts)
        (host: "http://${host}.internal:${toString conditions-port}");
      local = "http://127.0.0.1:${toString conditions-port}";
    };
    alerts = [ { url = alert-url; topic_file = "topic"; } ];
    apps = map plan-app apps;
    units = map plan-unit units;
    rows = map (row: builtins.removeAttrs row [ "heartbeat" ]) rows;
  };
}
