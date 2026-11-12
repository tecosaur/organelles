{ config, lib, pkgs, ... }:

let
  # the template test of whether the visitor's groups may use an app
  access-of = app: let
    groups = [ app.groups.primary ] ++ lib.optional (app.groups.admin != null) app.groups.admin ++ app.groups.extra;
  in "(or (not $groups) (any ${lib.concatMapStringsSep " " (group: ''(contains "${group}" $groups)'') groups}))";
  mkAppExport = name: app: let
    prefix = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name);
  in
    if app.enabled then
      {
        "${prefix}_SUBDOMAIN" = app.subdomain;
        "${prefix}_URL" = app.domain;
        "${prefix}_ACCESS" = access-of app;
        "${prefix}_ENABLED" = "true";
      } else
        {
          "${prefix}_SUBDOMAIN" = "<unknown>";
          "${prefix}_URL" = config.site.domain;
          "${prefix}_ACCESS" = "false";
          "${prefix}_ENABLED" = "false";
        };
  apps-exports = lib.concatMapAttrs mkAppExport config.site.apps;
  apps-env-export = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (key: val: "export ${key}='${val}'")
    apps-exports);
  app-env-vars = lib.concatStringsSep " " (lib.mapAttrsToList (k: _: "\$${k}") apps-exports);
  guides = lib.filter (app: app.enabled && app.guide != null) (lib.attrValues config.site.apps);
  static-root = pkgs.runCommand "static-root" { nativeBuildInputs = [ pkgs.gettext ]; } ''
      export DOMAIN='${config.site.domain}'
      export ACCENT='${config.site.accent.primary}'
      ${apps-env-export}
      export APPS_TEXT=$(cat <<'HEREDOC'
      ${lib.concatStringsSep "\n" (map (app: "• ${app.name} (${app.description})")
        (builtins.filter (app: app.enabled) (builtins.attrValues config.site.apps)))}
      HEREDOC
      )
      apply_template() {
          for file in "$@"; do
              tmpout=$(mktemp)
              envsubst '$DOMAIN $ACCENT $APPS_TEXT $WELCOME $GUIDES ${app-env-vars}' < "$file" > "$tmpout"
              mv "$tmpout" "$file"
          done
      }
      mkdir -p $out
      cp -r ${config.site.assets}/site-root/* $out
      cd $out
      apply_template index.txt welcome-public.html welcome-private.html
      cp index.html index-public.html
      export WELCOME=`sed 's/^/            /g' welcome-public.html`
      apply_template index-public.html
      cp index.html index-private.html
      export WELCOME=`sed 's/^/            /g' welcome-private.html`
      apply_template index-private.html
      rm index.html welcome-public.html welcome-private.html
      ${lib.concatMapStrings (app: ''
        URL=${lib.escapeShellArg app.domain} SUBDOMAIN=${lib.escapeShellArg app.subdomain} \
          ACCESS=${lib.escapeShellArg (access-of app)} envsubst '$URL $SUBDOMAIN $ACCESS' < ${app.guide} >> guides.html
      '') guides}
      export GUIDES=`sed 's/^/            /g' guides.html`
      rm guides.html
      apply_template services.html
    '';
in {
  services.caddy = {
      virtualHosts.${config.site.domain}.extraConfig = lib.concatLines (lib.mapAttrsToList
        (name: url: "redir /.well-known/${name} ${url}") config.site.well-known) + ''
        @browser-auth {
            header User-Agent *Mozilla*
            header Cookie *authelia_session*
        }
        @browser header User-Agent *Mozilla*
        try_files {path} {path}.html
        templates
        root ${static-root}
        route {
            handle /reload {
                header Clear-Site-Data "\"cache\""
                redir * /
            }
            handle @browser-auth {
                import auth
                file_server {
                    index index-private.html
                }
            }
            file_server @browser {
                index index-public.html
            }
            file_server {
                index index.txt
            }
        }
        '';
  };
}
