{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  ha = config.site.ha;
  inherit (ha) preference members voters;
  inherit (site-lib) mesh local;
  valkey-units = { valkey-ha = members; valkey-ha-sentinel = voters; valkey-ha-follow = preference; };
in {
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
          health_port ${toString config.site.ports.ha-serving.port}
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
  };

  config.site.ports = {
    ha-postgres = mesh 5433 "patroni" {
      patroni = members;
      postgresql-ha-setup = preference;
    };
    # Postgres asks each client's host on 113, which it can't be told otherwise
    ident = mesh 113 "oidentd" { patroni = members; };
    # its gRPC gateway dials its own client listener
    etcd = mesh 2379 "etcd" { patroni = members; etcd = voters; };
    etcd-peer = mesh 2380 "etcd" { etcd = voters; };
    etcd-metrics = local 2381 "etcd" [ "gatus-aggregator-report" ];
    patroni = mesh 8008 "patroni" { patroni = members; postgresql-ha-role = members; };
    # /serving answers 200 only on the serving member, for Caddy's health checks
    ha-serving = mesh 8009 "caddy" { caddy = hosts; } // { hosts = preference; };
    ha-valkey = mesh 6380 "valkey-ha" valkey-units;
    ha-sentinel = mesh 26379 "valkey-ha-sentinel" config.site.ports.ha-valkey.clients;
  };
  config.site.secrets = {
    # root's patronictl reads it too
    patroni-restapi = { kind = "key"; generate = "rand"; units = { patroni = members; postgresql-ha-role = members; }; };
    postgresql-ha-replication = { kind = "key"; generate = "rand"; units = { patroni = members; postgresql-ha-setup = preference; }; };
    valkey-ha = { kind = "key"; generate = "rand"; units = valkey-units; };
  };
}
