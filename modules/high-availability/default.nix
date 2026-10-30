{ config, lib, ... }:

let
  inherit (config.site) hosts;
  ha = config.site.ha;
in {
  imports = [ ./etcd.nix ./postgres.nix ./valkey.nix ];

  options.site.ha = {
    voters = lib.mkOption {
      type = lib.types.listOf (lib.types.enum hosts);
      default = hosts;
      description = ''
        The quorum: hosts whose agreement decides which member leads. Only
        the most reliable hosts should vote, since a majority of them must
        stay up for anything to fail over.
      '';
    };
    members = lib.mkOption {
      type = lib.types.listOf (lib.types.enum hosts);
      default = hosts;
      description = ''
        The hosts holding a copy of the replicated data. A host outside it,
        such as a voter kept for quorum alone, runs no instance and has no
        replication slot holding WAL back for it.
      '';
    };
    preference = lib.mkOption {
      type = lib.types.listOf (lib.types.enum ha.members);
      default = [ ];
      description = ''
        The members that serve, most preferred first: each carries every app
        that runs beside the primary, and leads in this order. A member not
        listed is promoted only when none of these can be, to keep what its
        acknowledgements made durable, and hands back by failback. Empty runs
        no replicated instance anywhere.
      '';
    };
    primary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if ha.preference == [ ] then null else lib.head ha.preference;
      description = "The most preferred member, where the cluster is first led from";
    };
    may-lead = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = lib.elem config.site.server.host ha.preference;
      description = "Whether this host may serve, and so must carry every app that runs beside the primary";
    };
    failback-minutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        How long a member preferred over the leader must have streamed
        before the leader hands over to it.
      '';
    };
    primary-proxy = lib.mkOption {
      type = lib.types.functionTo lib.types.lines;
      readOnly = true;
      default = port: ''
        reverse_proxy ${toString (map (host: "${host}.internal:${toString port}") ha.preference)} {
          lb_policy first
          health_uri /serving
          health_port ${toString ha.ports.serving}
          health_interval 2s
          lb_try_duration 15s
        }
      '';
      description = ''
        A Caddy directive proxying to a port on whichever preferred member
        serves: for an app that runs beside the primary alone, reachable
        through every host.
      '';
    };
    ports = {
      postgres = lib.mkOption {
        type = lib.types.port;
        default = 5433;
        description = "Port of the replicated Postgres, beside each host's local cluster on 5432";
      };
      etcd = lib.mkOption {
        type = lib.types.port;
        default = 2379;
        description = "Port etcd serves clients on";
      };
      etcd-peer = lib.mkOption {
        type = lib.types.port;
        default = 2380;
        description = "Port etcd's voters reach each other on";
      };
      patroni = lib.mkOption {
        type = lib.types.port;
        default = 8008;
        description = "Port of Patroni's REST API, whose /primary answers 200 only on the leader";
      };
      serving = lib.mkOption {
        type = lib.types.port;
        default = 8009;
        description = "Port whose /serving answers 200 only on the serving member, for Caddy's health checks";
      };
      valkey = lib.mkOption {
        type = lib.types.port;
        default = 6380;
        description = "Port of the replicated Valkey";
      };
      sentinel = lib.mkOption {
        type = lib.types.port;
        default = 26379;
        description = "Port Sentinel serves on, to its peers and to clients finding the Valkey master";
      };
    };
  };
}
