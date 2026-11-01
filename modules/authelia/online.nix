{ config, pkgs, ... }:

# On every host, as discovery is fetched through the public URL. Without
# RemainAfterExit, each start of a unit wanting it checks afresh.

{
  systemd.services.authelia-online = {
    description = "Wait for Authelia to serve its OIDC discovery";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.curl ];
    script = ''
      until curl -sf -o /dev/null --max-time 5 ${config.site.apps.authelia.url}/.well-known/openid-configuration; do
        sleep 2
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      # past this its dependents start anyway, and fail on their own terms
      TimeoutStartSec = "5min";
    };
    startLimitIntervalSec = 0;
  };
}
