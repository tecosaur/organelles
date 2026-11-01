{ config, lib, ... }:

# Every host offers its apps Stalwart's submission on loopback, through Caddy: to this host's
# Stalwart while it answers, else to another's over the mesh. Confinement lets only the apps'
# sending units reach it, so they send without a password, from their own addresses alone.

let
  mail = config.site.apps.mail;
  this-host = config.site.server.host;
  # this host's Stalwart first, then the rest by preference
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
            # a connection refused moves on to the next Stalwart, and marks this one down awhile
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
