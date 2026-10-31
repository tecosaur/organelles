{ config, lib, ... }:

# The shared Meilisearch backs Jellyfin's search through the Meilisearch plugin,
# which is installed from the repository registered below and takes its
# connection from the environment. The plugin rebuilds its index from Jellyfin
# on every start, so the state is a cache.

let
  jellyfin-env = "/run/jellyfin/meilisearch.env";
  # The plugin's index is the server's name, and a reindex builds <index>_rebuild beside it
  index = lib.replaceStrings [ " " ] [ "-" ] config.services.declarative-jellyfin.system.serverName;
in {
  site.meilisearch.keys.jellyfin = [ "${index}*" ];
  age.secrets.meilisearch-jellyfin = {
    owner = config.services.jellyfin.user;
    file = ../../secrets/keys/meilisearch-jellyfin.age;
  };

  services.declarative-jellyfin.system.pluginRepositories = [
    {
      tag = "RepositoryInfo";
      content = {
        Name = "Meilisearch";
        Url = "https://raw.githubusercontent.com/arnesacnussem/jellyfin-plugin-meilisearch/refs/heads/master/manifest.json";
      };
    }
  ];

  # The plugin prefers MEILI_URL and MEILI_MASTER_KEY, which takes any key, over
  # anything saved from its settings page, so the connection never depends on
  # state in the UI.
  # Without Meilisearch the plugin steps aside and Jellyfin's own search runs,
  # hence wants rather than requires.
  systemd.services.jellyfin = {
    wants = [ "meilisearch-keys.service" ];
    after = [ "meilisearch-keys.service" ];
    environment.MEILI_URL = config.site.meilisearch.url;
    preStart = ''
      umask 077
      echo "MEILI_MASTER_KEY=$(cat '${config.age.secrets.meilisearch-jellyfin.path}')" > '${jellyfin-env}'
    '';
    serviceConfig = {
      RuntimeDirectory = "jellyfin";
      RuntimeDirectoryMode = "0700";
      # Read at each exec, so the file preStart writes reaches the server;
      # the dash tolerates its absence while preStart itself runs.
      EnvironmentFile = "-${jellyfin-env}";
    };
  };
}
