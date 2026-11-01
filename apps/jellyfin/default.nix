{ config, lib, pkgs, ... }:

# Look at: <https://github.com/Sveske-Juice/declarative-jellyfin>
# Also see: <https://github.com/9p4/jellyfin-plugin-sso/issues/16#issuecomment-2953811762>

# Then also (https://gitlab.com/DomiStyle/jellysearch):
# - <https://git.vimium.com/jordan/nix-config/src/branch/master/pkgs/jellysearch>
# - <https://git.vimium.com/jordan/nix-config/src/branch/master/hosts/library/jellysearch.nix>

let
  app = config.site.apps.jellyfin;
  media-dir = "/data/media";
  movies-dir = "${media-dir}/movies";
  shows-dir = "${media-dir}/shows";
  anime-dir = "${media-dir}/anime";
  books-dir = "${media-dir}/books";
  music-dir = "${media-dir}/music";
in {
  imports = [ ./meilisearch.nix ];

  site.apps.jellyfin.enabled = true;

  services.declarative-jellyfin = {
    enable = true;
    package = pkgs.jellyfin;
    serverId = "f2d18e8c67994ce1baa11016df427c9f";
    backups = false;
    network = {
      enableIPv6 = true;
      enableHttps = false; # Handled by Caddy
      internalHttpPort = app.port;
      publicHttpPort = app.port;
      publishedServerUriBySubnet = [ "all=${app.url}" ];
    };
    encoding = {
      enableHardwareEncoding = true;
      hardwareAccelerationType = "vaapi";
      enableDecodingColorDepth10Hevc = true;
      allowHevcEncoding = true;
      allowAv1Encoding = true;
      hardwareDecodingCodecs = [
        "h264"
        "hevc"
        "mpeg2video"
        "vc1"
        "vp9"
        "vp8"
        "av1"
      ];
    };
    system = {
      serverName = "Media";
      trickplayOptions = {
        enableHwAcceleration = true;
        enableHwEncoding = true;
        enableKeyFrameOnlyExtraction = true;
        processThreads = 2;
      };
      pluginRepositories = [
        {
          tag = "RepositoryInfo";
          content = {
            Name = "Jellyfin Stable";
            Url = "https://repo.jellyfin.org/files/plugin/manifest.json";
          };
        }
        {
          tag = "RepositoryInfo";
          content = {
            Name = "SSO";
            # 9p4's builds stop at Jellyfin 10.11; this fork tracks 12.
            Url = "https://raw.githubusercontent.com/MaxRink/jellyfin-plugin-sso/manifest-release/manifest.json";
          };
        }
        {
          tag = "RepositoryInfo";
          content = {
            Name = "Intro Skipper";
            Url = "https://intro-skipper.org/manifest.json";
          };
        }
        {
          tag = "RepositoryInfo";
          content = {
            Name = "Dedup Continue Watching"; # No Jellyfin 12 build yet
            Url = "https://raw.githubusercontent.com/SloMR/jellyfin-plugin-dedupe-continue-watching/main/manifest.json";
          };
        }
        {
          tag = "RepositoryInfo";
          content = {
            Name = "Paradox Plugins";
            Url = "https://www.iamparadox.dev/jellyfin/plugins/manifest.json";
          };
        }
        {
          tag = "RepositoryInfo";
          content = {
            Name = "Jellyfin Tweaks";
            Url = "https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/12/manifest.json";
          };
        }
      ];
    };
    libraries = {
      Movies = {
        contentType = "movies";
        pathInfos = [ movies-dir ];
        typeOptions.Movies = {
          metadataFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
          imageFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
        };
      };
      Shows = {
        contentType = "tvshows";
        pathInfos = [ shows-dir ];
        enableAutomaticSeriesGrouping = true;
      };
      Anime = {
        contentType = "tvshows";
        pathInfos = [ anime-dir ];
        enableAutomaticSeriesGrouping = true;
      };
      Books = {
        contentType = "books";
        pathInfos = [ books-dir ];
      };
      Music = {
        contentType = "music";
        pathInfos = [ music-dir ];
        customTagDelimiters = [ "," "/" "|" ";" ];
      };
    };
    users = {
      admin = {
        mutable = false;
        hashedPassword = "$PBKDF2-SHA512$iterations=210000$EBADD66838EB56B9C6A7E475DF14548A$AB58132A66852B837ADE581C99964B7DEC9842DC7920933E06D3F18A7E41527B2C224F361DC490F5EBC35D83A9E31DA234F33FBBC9E7FBA122260982C28E888F";
        permissions = {
          isAdministrator = true;
        };
      };
    };
    branding = {
      loginDisclaimer = ''
      <form action="${app.url}/sso/OID/start/authelia">
        <button class="raised block emby-button button-submit">
          Sign in
        </button>
      </form>'';
      # Might want to try <https://github.com/lscambo13/ElegantFin> for 10.11, if Zesty isn't updated quickly
      customCss = builtins.readFile ./jellyfin.css;
    };
  };

  services.declarative-jellyfin.apikeys = lib.mkIf config.site.apps.multi-scrobbler.enabled {
    multi-scrobbler.keyPath = config.site.apps.multi-scrobbler.secrets.jellyfin.credentials.jellyfin;
  };

  # Declarative Jellyfin replaces the `ExecStart` of the `jellyfin`
  # service with a wrapper script, which means we can safely claim
  # `preStart` ourselves.
  systemd.services.jellyfin.preStart = let
    sso-template = builtins.replaceStrings [ "#oidc_endpoint#" ]
      [ config.site.apps.authelia.url ]
      (builtins.readFile ./jellyfin-sso-template.xml);
    sso-file = pkgs.writeText "jellyfin-sso.xml" sso-template;
    sso-path = "${config.services.jellyfin.dataDir}/plugins/configurations/SSO-Auth.xml";
    replaceSecretBin = lib.getExe pkgs.replace-secret;
    xmlstarlet = lib.getExe pkgs.xmlstarlet;
  in
    ''
    umask 007
    mkdir -p '${config.services.jellyfin.configDir}/plugins/configurations'
    # Preserve folder settings that cannot (easily) be managed declaratively
    if [ -f '${sso-path}' ]; then
        JELLY_OIDC_ENABLED_FOLDERS="$(${xmlstarlet} sel -t -c '//PluginConfiguration/OidConfigs[1]/item/value/PluginConfiguration/EnabledFolders' '${sso-path}' | sed '1d;$d')"
        JELLY_OIDC_FOLDER_ROLE_MAPPINGS="$(${xmlstarlet} sel -t -c '//PluginConfiguration/OidConfigs[1]/item/value/PluginConfiguration/FolderRoleMappings' '${sso-path}' | sed '1d;$d')"
    else
        JELLY_OIDC_ENABLED_FOLDERS=""
        JELLY_OIDC_FOLDER_ROLE_MAPPINGS=""
    fi
    mkdir -p "$(dirname '${sso-path}')"
    install -m 600 '${sso-file}' '${sso-path}'
    ${replaceSecretBin} '#oidc_secret#' '${app.auth.clients.jellyfin.secret.credential}' '${sso-path}'
    sed -i '/#enabled_folders#/{
      r /dev/stdin
      d
    }' '${sso-path}' <<<"$JELLY_OIDC_ENABLED_FOLDERS"
    sed -i '/#folder_role_mappings#/{
      r /dev/stdin
      d
    }' '${sso-path}' <<<"$JELLY_OIDC_FOLDER_ROLE_MAPPINGS"
    '';

  users.users.${config.services.jellyfin.user}.extraGroups = ["video" "render"];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };

  systemd.tmpfiles.rules = [
    "d ${media-dir} 0755 root users - -"
    "d ${movies-dir} 0775 ${config.services.jellyfin.user} users - -"
    "d ${shows-dir} 0775 ${config.services.jellyfin.user} users - -"
    "d ${anime-dir} 0775 ${config.services.jellyfin.user} users - -"
    # "d ${books-dir} 0575 ${config.services.jellyfin.user} users - -"
    "d ${music-dir} 0575 ${config.services.jellyfin.user} users - -"
  ];

  services.caddy.virtualHosts.${app.domain}.extraConfig =
    ''
    handle_path /web/assets/img/* {
        root ${config.site.assets}/jellyfin
        route {
            try_files {path} {http.request.uri}
            file_server {
                pass_thru
            }
            rewrite * {orig_uri}
            reverse_proxy :${toString app.port}
        }
    }
    handle /web/*.ico {
        rewrite * /jellyfin.ico
        root ${config.site.assets}/jellyfin
        file_server
    }
    reverse_proxy :${toString app.port}
    '';
}
