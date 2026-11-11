{ config, lib, site-lib, ... }:

let
  inherit (config.site) hosts;
  ha = config.site.ha;
  inherit (ha) preference members voters;
  inherit (site-lib) mesh local;
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
        acknowledgements made durable, and hands back by failback. Empty
        keeps the shared databases unreplicated, on site.databases.host.
      '';
    };
    failback-minutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        How long a member preferred over the leader must have streamed
        before the leader hands over to it.
      '';
    };
  };

  config = lib.mkIf config.site.databases.replicated {
    assertions = [ {
      assertion = lib.length preference > 1;
      message = "site.ha.preference names only ${toString preference}; replication needs two hosts to serve, so set site.databases.host = \"${lib.head preference}\" instead";
    } ];
    site.databases = {
      servers = {
        hosts = members;
        postgres = { unit = "patroni"; port = 5433; socket-dir = "/run/postgresql-ha"; };
        valkey = { unit = "valkey-ha"; port = 6380; };
        primary-env = "/run/postgresql-ha-role/primary.env";
      };
      valkey.default.units = { valkey-ha-sentinel = voters; valkey-ha-follow = preference; };
    };
    site.ports = {
      postgres.clients = { patroni = members; postgresql-ha-setup = preference; };
      etcd = mesh 2379 "etcd" { patroni = members; };
      etcd-peer = mesh 2380 "etcd" { etcd = voters; };
      etcd-metrics = local 2381 "etcd" [ "gatus-aggregator-report" ];
      patroni = mesh 8008 "patroni" { patroni = members; postgresql-ha-role = members; };
      ha-sentinel = mesh 26379 "valkey-ha-sentinel" config.site.ports.valkey.clients;
    };
    site.secrets = {
      # Sentinel takes the shared password, as the default user, from every client
      valkey-default.units = config.site.ports.valkey.clients;
      # root's patronictl reads it too
      patroni-restapi = { kind = "key"; generate = "rand"; units = { patroni = members; postgresql-ha-role = members; }; };
      postgresql-ha-replication = { kind = "key"; generate = "rand"; units = { patroni = members; postgresql-ha-setup = preference; }; };
    };
  };
}
