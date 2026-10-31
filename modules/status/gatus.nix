{ config, lib, pkgs, ... }:

# Gatus runs beside the HA Postgres primary alone, wherever that is,
# keeping its history there: two instances sharing one database would
# record every result twice. Every preferred member's Caddy proxies to it.
# Nothing in its configuration is written by hand; every row comes from
# plan.nix, and gatus-aggregator pushes them all.

let
  inherit (config.site) domain;
  app = config.site.apps.gatus;
  status = import ./plan.nix { inherit config lib; };
  page-domain = "${app.subdomain}.${domain}";
  start = pkgs.writeShellScript "gatus-start" ''
    GATUS_PUSH_TOKEN="$(< "$CREDENTIALS_DIRECTORY/push")"
    GATUS_ALERT_TOPIC="$(< "$CREDENTIALS_DIRECTORY/topic")"
    export GATUS_PUSH_TOKEN GATUS_ALERT_TOPIC
    exec ${lib.getExe config.services.gatus.package}
  '';
in {
  config = lib.mkIf config.site.ha.may-lead {
    site.apps.gatus.enabled = true;

    services.ha.postgres.databases = [ "gatus" ];

    services.gatus = {
      enable = true;
      settings = {
        web.port = app.port;
        # The primary, by PGHOST and PGPORT; ident authenticates the gatus system user. The mesh
        # encrypts, and lib/pq, unlike libpq, refuses a server without TLS unless told
        storage = {
          type = "postgres";
          path = "user=gatus dbname=gatus sslmode=disable";
        };
        alerting.ntfy = {
          url = status.alert-url;
          topic = "\${GATUS_ALERT_TOPIC}";
          priority = 4;
        };
        inherit (status) external-endpoints;
        # Gatus insists on one endpoint it polls itself; the alert route is
        # the one thing nothing else watches
        endpoints = [ {
          group = status.gatus-group;
          name = "Alert delivery";
          url = "${status.alert-url}/v1/health";
          interval = "5m";
          conditions = [ "[STATUS] == 200" "[BODY].healthy == true" ];
          ui.hide-url = true;
        } ];
        ui = {
          title = "Status of ${domain}";
          description = "Live health of the machines and services running ${domain}.";
          header = domain;
          dashboard-heading = "Status";
          dashboard-subheading = "Live health of the machines and services running ${domain}.";
          logo = "/brand/logo.svg";
          link = "https://${domain}";
          favicon.default = "/brand/favicon.svg";
          buttons = [
            { name = "Home"; link = "https://${domain}"; }
            { name = "Services"; link = "https://${domain}/services"; }
          ];
          custom-css = import ./theme.nix { inherit (config.site) accent; };
          default-sort-by = "group";
          # follow the visitor's own light or dark preference
          dark-mode = false;
        };
      };
    };

    users.users.gatus = {
      isSystemUser = true;
      group = "gatus";
    };
    users.groups.gatus = { };

    systemd.tmpfiles.settings."10-gatus-config" = {
      ${status.config-dir}.d = { user = "gatus"; group = "gatus"; mode = "0755"; };
      "${status.config-dir}/00-site.yaml"."L+".argument = "${config.services.gatus.configFile}";
      # the announcement Gatus once reloaded for, now the aggregator's to serve
      "${status.config-dir}/50-announcement.yaml".r = { };
    };

    systemd.services.gatus = {
      # the configuration is read through a link that never moves
      environment.GATUS_CONFIG_PATH = lib.mkForce status.config-dir;
      restartTriggers = [ config.services.gatus.configFile ];
      # Gatus exits when its database is unreachable; keep trying
      startLimitIntervalSec = 0;
      serviceConfig = {
        # peer authentication needs the system user the database is named for
        DynamicUser = lib.mkForce false;
        ExecStart = lib.mkForce start;
        LoadCredential = [
          "push:${config.age.secrets.gatus-push.path}"
          "topic:${config.age.secrets.status-alert-topic.path}"
        ];
        RestartSec = "10s";
      };
    };

    services.caddy.virtualHosts.${page-domain}.extraConfig = ''
      @push path /api/v1/endpoints/*/external
      respond @push 403
      # The page reads its announcement here: from the aggregator beside Gatus, which serves it
      # without Gatus reloading, else from Gatus itself, without one
      @config path /api/v1/config
      handle @config {
          reverse_proxy ${toString (lib.concatMap (host: [
            "${host}.internal:${toString status.announcement-port}"
            "${host}.internal:${toString app.port}"
          ]) config.site.ha.preference)} {
              lb_policy first
              health_uri /serving
              health_port ${toString config.site.ha.ports.serving}
              health_interval 2s
              lb_try_duration 5s
          }
      }
      handle_path /brand/* {
          root * ${config.site.assets}/site
          file_server
      }
      ${config.site.ha.primary-proxy app.port}
    '';
  };
}
