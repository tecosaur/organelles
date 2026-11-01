{ config, lib, site-lib, ... }:

let
  inherit (config.site.meilisearch) host;
  inherit (config.site.ports.meilisearch) port;
  inherit (site-lib) mesh;
  on = app: config.site.apps.${app}.hosts;
in {
  options.site.meilisearch = {
    host = lib.mkOption {
      type = lib.types.str;
      example = "nucleus";
      description = "The host that runs Meilisearch";
    };
    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "http://${host}.internal:${toString port}";
      description = "Where every host reaches Meilisearch";
    };
    keys = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nonEmptyListOf lib.types.str);
      default = { };
      example = { stalwart = [ "st_*" ]; };
      description = ''
        Each client's key, by name, and the index patterns it may use. Its
        secret is declared with generate = "meilisearch", which makes
        keys/meilisearch-<name>.age and its .uid.
      '';
    };
  };

  config.site.ports = {
    meilisearch = mesh 7700 "meilisearch" {
      stalwart = on "mail";
      jellyfin = on "jellyfin";
      meilisearch-keys = [ config.site.meilisearch.host ];
    } // { hosts = [ config.site.meilisearch.host ]; };
  };
  config.site.secrets = {
    # the server loads it itself; meilisearch-keys declares the clients' keys with it
    meilisearch-master = { kind = "key"; generate = "rand"; hosts = [ host ]; units = [ "meilisearch-keys" ]; };
  };
}
