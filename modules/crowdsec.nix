{ config, lib, pkgs, ... }:

# With thanks to <https://github.com/xddxdd/nixos-config/blob/master/nixos/server-apps/crowdsec.nix>

let
  crowdsec-port = config.site.ports.crowdsec-api.port;
  data-dir = config.services.crowdsec.settings.config.config_paths.data_dir;
  caddy-logs = config.services.caddy.logDir;
in {
  # Caddy creates its logs owner-only unless told otherwise
  options.services.caddy.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      config.logFormat = lib.mkDefault ''
        output file ${caddy-logs}/access-${name}.log {
          mode 0640
        }
      '';
    }));
  };

  config = {
    age.secrets.crowdsec-enroll-key.file = ../secrets/credentials/crowdsec-enroll-key.age;

    services.crowdsec = {
      enable = true;
      autoUpdateService = true;
      # Caddy's access logs, which its group may read
      extraGroups = lib.optional config.services.caddy.enable config.services.caddy.group;
      readOnlyPaths = lib.optional config.services.caddy.enable caddy-logs;
      hub = {
        collections = [
          "crowdsecurity/linux"
          "crowdsecurity/caddy"
          "crowdsecurity/sshd"
        ];
        scenarios = [
          "crowdsecurity/http-bad-user-agent"
          "crowdsecurity/http-crawl-non_statics"
          "crowdsecurity/http-probing"
        ];
        postoverflows = [
          "crowdsecurity/cdn-qc-whitelsit"
          "crowdsecurity/cdn-whitelist"
          "crowdsecurity/discord-crawler-whitelist"
          "crowdsecurity/ipv6_to_range"
          "crowdsecurity/rdns"
          "crowdsecurity/seo-bots-whitelist"
        ];
      };
      settings = {
        simulation.simulation = false;
        acquisitions = lib.optional config.services.openssh.enable {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
          labels.type = "syslog";
        } ++ lib.optional config.services.caddy.enable {
          source = "file";
          filenames = [ "${caddy-logs}/access-*.log" ];
          labels.type = "caddy";
        };
        # Peers reach each other's Caddy over the mesh (health checks, JMAP
        # forwarding, status reports), and banning one would cut it off; the
        # stock whitelist covers private IPv4 but no IPv6 ULA.
        parsers.s02Enrich = [ {
          name = "site/whitelist";
          description = "Never act on loopback, private networks, or the mesh";
          whitelist = {
            reason = "the site's own hosts";
            ip = [ "::1" ];
            cidr = [ "127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
                     "${config.site.mesh.subnet}/64" ];
          };
        } ];
        console.enrollKeyFile = config.age.secrets.crowdsec-enroll-key.path;
        config.api.server = {
          listen_uri = "127.0.0.1:${toString crowdsec-port}";
          online_client.credentials_path = "${data-dir}/online_api_credentials.yaml";
        };
      };
    };

    # mode applies to files Caddy creates, not those it already has
    systemd.tmpfiles.rules = lib.mkIf config.services.caddy.enable [
      "z ${caddy-logs}/access-*.log 0640 ${config.services.caddy.user} ${config.services.caddy.group} -"
    ];

    services.crowdsec-firewall-bouncer = {
      enable = true;
      registerBouncer.enable = true;
      settings = {
        update_frequency = "10s";
        deny_action = "DROP";
      };
    };
  };
}
