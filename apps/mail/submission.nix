{ config, lib, ... }:

# Apps submit on loopback to Caddy, which proxies to a healthy Stalwart. Confinement admits
# only their sending units, so they need no password.

let
  mail = config.site.apps.mail;
  this-host = config.site.server.host;
  servers = lib.filter (host: lib.elem host mail.hosts)
    (lib.unique ([ this-host ] ++ config.site.ha.preference ++ mail.hosts));
in {
  services.caddy.globalConfig = ''
    layer4 {
      127.0.0.1:${toString mail.ports.submission-local.port} {
        route {
          proxy {
            ${lib.concatMapStrings (host: ''
              upstream [${config.site.mesh.addresses.${host}}]:${toString mail.ports.submission-mesh.port}
            '') servers}
            lb_policy first
            lb_try_duration 10s
            fail_duration 30s
            max_fails 1
            health_interval 10s
            health_timeout 3s
          }
        }
      }
    }
  '';
}
