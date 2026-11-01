{ config, lib, site-lib, ... }:

{
  options.site.apps.koito = site-lib.mkAppOption {
    health.path = "/apis/web/v1/health";
    name = "Koito";
    homepage = "https://koito.io";
    description = "listening history";
    subdomain = "listens";
    port = 4110;
    # its start checks it serves
    clients = [ "multi-scrobbler" "koito" ];
    extraOptions = {
      title = lib.mkOption {
        type = lib.types.str;
        default = "Koito";
        description = "Title of the Koito app";
      };
    };
    secrets = {
      admin-password = { kind = "password"; description = "Koito admin login"; };
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
      deezer-arl = { kind = "credential"; description = "Deezer arl login cookie, for multi-scrobbler"; optional = true; file-name = "deezer-arl"; };
      listenbrainz-token = { kind = "credential"; description = "ListenBrainz user token, for multi-scrobbler"; optional = true; file-name = "listenbrainz-token"; };
      jellyfin = { kind = "key"; generate = "rand"; };
      koito = { kind = "key"; generate = "rand"; };
      endpoint-token = { kind = "password"; description = "Token Lyrion's AudioScrobbler plugin presents to multi-scrobbler's ListenBrainz endpoint"; };
    };
  };
}
