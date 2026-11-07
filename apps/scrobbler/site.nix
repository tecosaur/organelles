{ config, lib, site-lib, ... }:

{
  # Its proxy is public, like a ListenBrainz profile; Koito's own login guards editing
  options.site.apps.koito = site-lib.mkAppOption {
    health.path = "/apis/web/v1/health";
    name = "Koito";
    homepage = "https://koito.io";
    description = "listening history";
    subdomain = "listens";
    port = 4110;
    clients = [ "multi-scrobbler" ];
    extraOptions = {
      title = lib.mkOption {
        type = lib.types.str;
        default = "Koito";
        description = "Title of the Koito app";
      };
    };
    secrets = {
      admin-password = { kind = "password"; description = "Koito admin login"; units = [ "koito" ]; };
    };
  };
  options.site.apps.multi-scrobbler = site-lib.mkAppOption {
    # the Koito client alone: the full check fails whenever any upstream
    # scrobbling service is down
    health.path = "/api/health?type=koito";
    name = "Multi-Scrobbler";
    homepage = "https://foxxmd.github.io/multi-scrobbler";
    description = "scrobble collector";
    subdomain = "scrobbler";
    port = 9078;
    proxy = false;
    extraOptions = {
      jellyfin-user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The Jellyfin account whose plays are scrobbled";
      };
      listenbrainz-user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The ListenBrainz account listens are relayed to";
      };
    };
    auth.access.subject = [ "group:${config.site.apps.multi-scrobbler.groups.admin}" ];
    secrets = {
      deezer-arl = { kind = "credential"; description = "Deezer arl login cookie, for multi-scrobbler"; optional = true; file-name = "deezer-arl"; units = [ "multi-scrobbler" ]; };
      listenbrainz-token = { kind = "credential"; description = "ListenBrainz user token, for multi-scrobbler"; optional = true; file-name = "listenbrainz-token"; units = [ "multi-scrobbler" ]; };
      jellyfin = {
        kind = "key";
        generate = "rand";
        units.multi-scrobbler = config.site.apps.multi-scrobbler.hosts;
      };
      koito = { kind = "key"; generate = "rand"; units = [ "koito" "multi-scrobbler" ]; };
      endpoint-token = { kind = "password"; description = "Token Lyrion's AudioScrobbler plugin presents to multi-scrobbler's ListenBrainz endpoint"; units = [ "multi-scrobbler" ]; };
    };
  };
}
