{ config, lib, pkgs, ... }:

let
  trek = config.site.apps.trek;
  trek-domain = "${trek.subdomain}.${config.site.domain}";
  trek-pkg = pkgs.callPackage ./package.nix { };
  # A tree of links to the package: the server writes beside its own location.
  trek-runtime = "${trek.dir}/runtime";
  trek-plugins-dir = "${trek-runtime}/server/data/plugins";
  trek-secrets-env = "/run/trek/secrets.env";
  # Where TREK itself keeps it: server/data is linked to ${trek.dir}/data.
  trek-encryption-key = "${trek.dir}/data/.encryption_key";
  # Authoritative: dropping a plugin from here uninstalls it on the next start.
  trek-plugins = map trek-fetch-plugin [
    {
      id = "flight-tracker";
      src = "fbnlrz/trek-track@v2.0.0";
      hash = "sha256-r++zNN+tzjKLSLIvSSlc8jKRPCA6jRIEYfhe25r9MO0=";
      settings.aerodatabox_key = config.site.apps.trek.secrets.aerodatabox-key.credential;
    }
  ];
  trek-fetch-plugin = { id, src, hash, settings ? { } }:
    let parts = builtins.match "([^/]+)/([^@]+)@(.+)" src; in
    if parts == null
    then throw ''trek: plugin source must be "owner/repo@rev", got "${src}"''
    else {
      inherit id settings;
      src = pkgs.fetchzip {
        name = "trek-plugin-${id}";
        url = "https://github.com/${builtins.elemAt parts 0}/${
          builtins.elemAt parts 1}/archive/${builtins.elemAt parts 2}.tar.gz";
        inherit hash;
        # In the fetch, so the hash covers what is actually served.
        postFetch = ''
          find $out -name '*.html' -exec ${
            lib.getExe trek-pkg.passthru.injectUi} {} +
        '';
      };
    };
  trek-plugin-manifest = pkgs.writeText "trek-plugins" (lib.concatMapStrings
    (p: "${p.id} ${p.src}\n") trek-plugins);
  # Plugins have no operator-level surface (unlike the API keys, which are env
  # vars), so this drives TREK's own services: the admin API needs a session, and
  # an OIDC-only instance has no credential to present. The container is created
  # but never initialised, so no boot hook runs and no plugin is spawned here; the
  # server activates every enabled row when it starts.
  trek-reconcile = pkgs.writeText "trek-reconcile.js" ''
    process.env.NODE_ENV = 'production';

    const fs = require('node:fs');
    const path = require('node:path');
    // Written by the same preStart, so the unit's EnvironmentFile predates it
    process.loadEnvFile(process.argv[2]);
    // This file is in the store; the code it drives is in the runtime tree.
    const serverRequire = require('node:module').createRequire(
      path.join(process.cwd(), 'noop.js'));
    serverRequire('reflect-metadata');
    serverRequire('tsconfig-paths/register');

    const { NestFactory } = serverRequire('@nestjs/core');
    const { MikroORM } = serverRequire('@mikro-orm/core');
    const { AppModule } = serverRequire('./dist/nest/app.module');
    const { DatabaseLifecycle } = serverRequire('./dist/nest/database/database-lifecycle.service');
    const { withRequestContext } = serverRequire('./dist/nest/database/request-context');
    const { PluginsRepository } = serverRequire('./dist/db/repositories/Plugins.repository');
    const { PluginsService } = serverRequire('./dist/nest/plugins/plugins.service');
    const { PluginRuntimeService } = serverRequire('./dist/nest/plugins/plugin-runtime.service');
    const { hostSatisfies, hostVersion } = serverRequire('./dist/nest/plugins/install/host-compat');
    const { isKnownPermission } = serverRequire('./dist/nest/plugins/protocol/envelope');

    const declared = ${builtins.toJSON
      (map (p: { inherit (p) id settings; }) trek-plugins)};

    async function reconcilePlugins(app) {
      const runtime = app.get(PluginRuntimeService, { strict: false });
      const pluginsService = app.get(PluginsService, { strict: false });
      const plugins = app.get(PluginsRepository, { strict: false });
      const { skipped } = await runtime.rescan();
      for (const id of skipped) console.warn(`trek: plugin ''${id} failed discovery`);

      const wanted = new Set(declared.map((p) => p.id));
      for (const { id } of await plugins.listDepRows()) {
        if (wanted.has(id)) continue;
        console.log(`trek: uninstalling undeclared plugin ''${id}`);
        await runtime.uninstall(id, false);
      }

      for (const { id, settings } of declared) {
        const row = await plugins.findActivationGate(id);
        if (!row) {
          console.warn(`trek: declared plugin ''${id} was not discovered`);
          continue;
        }
        for (const [key, file] of Object.entries(settings)) {
          try {
            const value = fs.readFileSync(file, 'utf8').trim();
            if (value) await pluginsService.updateInstanceConfig(id, { [key]: value });
          } catch (err) {
            console.warn(`trek: ''${id}.''${key} not set: ''${err.message}`);
          }
        }
        // Declaring a plugin is the operator's consent to run it, outside its
        // author's TREK range included; renewed each start, as TREK asks again
        // after a plugin update or a new major.
        if (row.version && !hostSatisfies(row.trek_range)) {
          console.warn(`trek: running ''${id} outside its TREK range ''${row.trek_range}`);
          await plugins.acceptTrekRange(id, row.version, hostVersion());
        }
        const permissions = JSON.parse(row.permissions || '[]').filter(isKnownPermission);
        await plugins.grantPermissionsAndEnable(id, JSON.stringify(permissions));
      }
    }

    // Not worth failing the unit for: that keeps the site down over stale plugins.
    async function main() {
      const app = await NestFactory.create(AppModule, { logger: ['error', 'warn'] });
      try {
        await app.get(DatabaseLifecycle).open();
        await withRequestContext(app.get(MikroORM), () => reconcilePlugins(app));
      } finally {
        await app.close();
      }
    }

    main()
      .catch((err) => console.error(`trek: plugin reconcile failed: ''${err.stack || err.message}`))
      .finally(() => process.exit(0));
  '';
in {
  site.apps.trek.enabled = true;

  systemd.services.trek = {
    description = "TREK collaborative travel planner";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      NODE_ENV = "production";
      PORT = toString trek.port;
      APP_URL = "https://${trek-domain}";
      TZ = config.time.timeZone;
      TRUST_PROXY = "1";
      FORCE_HTTPS = "false";
      COOKIE_SECURE = "true";
      TREK_PLUGINS_DIR = trek-plugins-dir;
      # "Someone other than the admin owns the config": Nix does. This is what
      # makes MAPBOX_ACCESS_TOKEN take effect, and it locks the operator-supplied
      # settings in the admin UI along with UI backup/restore, plugin sideloading
      # and the home-server integrations (Immich, AirTrail).
      TREK_MANAGED = "true";
      OIDC_ISSUER = "https://${config.site.apps.authelia.subdomain}.${config.site.domain}";
      OIDC_CLIENT_ID = "trek";
      OIDC_DISPLAY_NAME = "Authelia";
      OIDC_ONLY = "true";
      OIDC_SCOPE = "openid email profile groups";
      OIDC_ADMIN_CLAIM = "groups";
      OIDC_ADMIN_VALUE = trek.groups.admin;
    };
    preStart = ''
      find ${trek-runtime}/server -mindepth 1 -maxdepth 1 ${
        lib.concatMapStringsSep " " (n: "! -name ${n}") trek-pkg.stateLinks
      } -exec rm -rf {} +
      find ${trek-runtime} -mindepth 1 -maxdepth 1 ! -name server -exec rm -rf {} +
      for entry in ${trek-pkg}/lib/trek/*; do
        [ "$(basename "$entry")" = server ] && continue
        ln -s "$entry" ${trek-runtime}/"$(basename "$entry")"
      done
      for entry in ${trek-pkg}/lib/trek/server/*; do
        ln -s "$entry" ${trek-runtime}/server/"$(basename "$entry")"
      done
      # Real and writable, not a link (see passthru.stateLinks).
      rm -f ${trek-runtime}/server/dist
      cp -r ${trek-pkg}/lib/trek/server/dist ${trek-runtime}/server/dist
      chmod -R u+w ${trek-runtime}/server/dist
      ${lib.concatMapStringsSep "\n" (name: ''
        mkdir -p /var/lib/trek/${name}
        ln -sfn /var/lib/trek/${name} ${trek-runtime}/server/${name}
      '') trek-pkg.stateLinks}

      # Copied, not linked: discovery skips realpaths outside the plugins root.
      rm -rf ${trek-plugins-dir} || true
      install -d -m 0750 ${trek-plugins-dir}
      while read -r id path; do
        cp -r "$path" ${trek-plugins-dir}/"$id"
        chmod -R u+w ${trek-plugins-dir}/"$id"
      done < ${trek-plugin-manifest}

      umask 077
      # Managed mode insists the at-rest key arrive by env rather than be found in
      # the data volume. It is the key TREK already persisted (any other would
      # orphan every stored secret), so it stays state, minted here only once.
      [ -s ${trek-encryption-key} ] || ${lib.getExe pkgs.openssl} rand -hex 32 > ${trek-encryption-key}
      # Env vars, not the database: TREK reads these ahead of any stored key.
      { echo "ENCRYPTION_KEY=$(cat ${trek-encryption-key})"
        echo "OIDC_CLIENT_SECRET=$(cat ${config.site.apps.trek.auth.clients.trek.secret.credential})"
        echo "UNSPLASH_ACCESS_KEY=$(cat ${config.site.apps.trek.secrets.unsplash-key.credential})"
        echo "PLACES_API_KEY=$(cat ${config.site.apps.trek.secrets.maps-key.credential})"
        echo "MAPBOX_ACCESS_TOKEN=$(cat ${config.site.apps.trek.secrets.mapbox-token.credential})"
      } > ${trek-secrets-env}

      ${lib.getExe pkgs.nodejs} ${trek-reconcile} ${trek-secrets-env}
    '';
    serviceConfig = {
      User = "trek";
      Group = "trek";
      ExecStart = "${lib.getExe trek-pkg}";
      Restart = "on-failure";
      RestartSec = 10;
      StateDirectory = "trek trek/runtime trek/runtime/server";
      RuntimeDirectory = "trek";
      RuntimeDirectoryMode = "0700";
      WorkingDirectory = "${trek-runtime}/server";
      EnvironmentFile = "-${trek-secrets-env}";
      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      RestrictSUIDSGID = true;
      LimitNOFILE = 65536;
    };
  };

  users.users.trek = {
    isSystemUser = true;
    group = "trek";
  };

  users.groups.trek = { };

  services.caddy.virtualHosts.${trek-domain}.extraConfig = ''
    # Listed, not globbed: TREK serves its own /icons too.
    @custom-icons {
        path /icons/icon.svg
        path /icons/icon-192x192.png
        path /icons/icon-512x512.png
        path /icons/apple-touch-icon-180x180.png
    }
    handle @custom-icons {
        root ${config.site.assets}/trek
        file_server
    }
    reverse_proxy :${toString trek.port}
  '';
}
