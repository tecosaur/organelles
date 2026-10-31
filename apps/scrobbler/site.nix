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
  };
  config.site.apps.koito = {
    title = "Listens";
    groups.primary = "listens";
  };
  config.site.apps.multi-scrobbler = {
    jellyfin-user = "tec";
    listenbrainz-user = "tecosaur";
  };
}
