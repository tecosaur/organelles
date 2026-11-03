{ config, lib, pkgs, ... }:

# A static mesh for inter-node traffic, off the tailnet so it depends on no
# service the cluster hosts.

let
  inherit (config.site) hosts;
  inherit (config.site.ports.wireguard) port;
  this-host = config.site.server.host;
  address = name: config.site.mesh.addresses.${name};
  key-file = name: ../secrets/keys + "/wg-${name}.pub";
  public-key = name: lib.removeSuffix "\n" (builtins.readFile (key-file name));
  mesh-servers = lib.unique (map (listener: listener.unit) (lib.filter (listener:
    listener.exposure == "mesh" && listener.unit != null && lib.elem this-host listener.hosts)
    config.site.listeners));
  unkeyed = lib.filter (name: !builtins.pathExists (key-file name)) hosts;
  mkPeer = name: {
    PublicKey = public-key name;
    AllowedIPs = [ "${address name}/128" ];
    Endpoint = "${name}.${config.site.dns.host-domain}.${config.site.domain}:${toString port}";
    # 15s rather than the conventional 25s: dns-pooler reads liveness from the
    # per-peer receive counter, which only advances as fast as keepalives arrive.
    PersistentKeepalive = 15;
  };
in
{
  assertions = [
    { assertion = unkeyed == [ ];
      message = "wireguard-mesh: no key for ${lib.concatStringsSep ", " unkeyed}; "
                + "run `./secrets/make.sh wireguard`, then `git add secrets/keys`";
    }
    (let collided = lib.filter
           (name: lib.any (other: other != name && address other == address name) hosts)
           hosts;
     in { assertion = collided == [ ];
          message = "wireguard-mesh: ${lib.concatStringsSep ", " collided} share a mesh "
                    + "address; rename one, or widen the host bits in site.mesh.subnet";
        })
    { assertion = lib.elem this-host hosts;
      message = "wireguard-mesh: ${this-host} is not in site.hosts, so it has no mesh address";
    }
  ];

  # the mesh has no unit of its own; dns-pooler's view of its peers stands in
  site.status.units = [ { id = "mesh"; name = "Mesh"; kind = "mesh"; } ];

  networking.hosts = lib.listToAttrs
    (map (name: lib.nameValuePair (address name) [ "${name}.internal" ]) hosts);

  environment.systemPackages = [ pkgs.wireguard-tools ];

  systemd.network = {
    netdevs."50-wg0" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = "wg0";
      };
      wireguardConfig = {
        ListenPort = port;
        PrivateKeyFile = config.site.secrets."wg-${this-host}".decrypted;
      };
      wireguardPeers = map mkPeer (lib.filter (n: n != this-host) hosts);
    };
    networks."50-wg0" = {
      matchConfig.Name = "wg0";
      address = [ "${address this-host}/64" ];
      linkConfig.RequiredForOnline = "no";
    };
    wait-online.ignoredInterfaces = [ "wg0" ];
  };

  # wg0 stays out of network-online.target, so units binding its address wait on it alone
  systemd.services = lib.genAttrs mesh-servers (_: {
    wants = [ "wg0-online.service" ];
    after = [ "wg0-online.service" ];
  }) // {
    wg0-online = {
      description = "Wait for wg0 to have its mesh address";
      bindsTo = [ "systemd-networkd.service" ];
      after = [ "systemd-networkd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface=wg0:routable";
      };
    };
  };
}
