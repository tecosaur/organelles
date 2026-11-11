{ config, lib, ... }:

# Each app's virtual host starts with its branding and ends in a proxy to its port. Branding
# goes first since Caddy keeps the source order of handles it cannot rank by a single path.

let
  inherit (config.site) databases;
  this-host = config.site.server.host;
  # hosts is filled only in the flake's final evaluation; before it, enabled says what runs here
  runs-here = app: if app.hosts == [ ] then app.enabled else lib.elem this-host app.hosts;
  # Requests are the only probes, so nothing is asked while the first is well: one that cannot
  # connect tries the next, and one answered as down or starting passes that instance over for
  # a while, after relaying that answer.
  # The dial timeout bounds what an unreachable host costs, and the try duration rides out a
  # changeover, when every instance may refuse for a few seconds.
  failover = ''
    lb_policy first
    lb_try_duration 15s
    fail_duration 10s
    unhealthy_status 502 503 504
    transport http {
        dial_timeout 2s
    }
  '';
  # An app's instances: this host's first, unless it prefers the primary, then in preference order
  instances = app: let
    hosts = lib.unique (lib.optional (!app.prefersPrimary && lib.elem this-host app.hosts) this-host
      ++ lib.filter (host: lib.elem host app.hosts) databases.hosts ++ app.hosts);
  in if lib.length hosts < 2 then [ ":${toString app.port}" ]
    else map (host: "${host}.internal:${toString app.port}") hosts;
  balancing = upstreams: lib.optionalString (lib.length upstreams > 1) failover;
  proxy-to = upstreams: ''
    reverse_proxy ${toString upstreams} {
        ${balancing upstreams}
    }
  '';
  upstream = app: let to = instances app; in { to = toString to; balancing = balancing to; };
  reverse-proxy = app: if app.followsPrimary then databases.primary-proxy app.port else proxy-to (instances app);
  branding-handle = path: file: let
    directory = lib.hasSuffix "/" file;
    prefix = lib.removeSuffix "/" (lib.head (builtins.match "([^*]*/).*" path));
  in ''
    handle ${path} {
        root * ${config.site.assets}/${if directory then lib.removeSuffix "/" file else dirOf file}
        ${if !directory then "rewrite * /${baseNameOf file}"
          else lib.optionalString (prefix != "") "uri strip_prefix ${prefix}"}
        file_server
    }
  '';
  apps = lib.filter (app: runs-here app && (app.proxy || app.branding != { })) (lib.attrValues config.site.apps);
in {
  options.site = {
    proxy-to = lib.mkOption {
      type = lib.types.functionTo lib.types.lines;
      readOnly = true;
      default = proxy-to;
      description = "A Caddy directive proxying to a list of upstreams, tried in order where there are several";
    };
    upstream = lib.mkOption {
      type = lib.types.functionTo lib.types.attrs;
      readOnly = true;
      default = upstream;
      description = ''
        An app's instances for a Caddy proxy: `to`, this host's first, unless
        the app prefers the primary, then those in site.databases.hosts order, and
        their `balancing`, the settings trying them in order where there are several.
      '';
    };
    proxy = lib.mkOption {
      type = lib.types.functionTo lib.types.lines;
      readOnly = true;
      default = reverse-proxy;
      description = ''
        A Caddy directive proxying to an app by site.upstream, or to the
        serving member for an app that follows the primary.
      '';
    };
  };

  config.services.caddy.virtualHosts = lib.listToAttrs (map (app: lib.nameValuePair app.domain {
    extraConfig = lib.mkMerge (lib.optional (app.branding != { })
        (lib.mkBefore (lib.concatStrings (lib.mapAttrsToList branding-handle app.branding)))
      ++ lib.optional app.proxy (lib.mkAfter (reverse-proxy app)));
  }) apps);
}
