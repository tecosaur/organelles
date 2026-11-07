{ config, lib, pkgs, ... }:

let
  app = config.site.apps.mealie;
  mealie-user = "mealie";
  darkenHex = rgb: let
    min = a: b: if a < b then a else b;
    max = a: b: if a > b then a else b;
    clamp = lo: hi: x: max lo (min hi x);
    hexDigits = lib.stringToCharacters "0123456789abcdef";
    toHex = n:
      let
        nn = clamp 0 255 n;
        hi = builtins.floor (nn / 16);
        lo = builtins.floor (nn - hi * 16);
      in
        (builtins.elemAt hexDigits hi) + (builtins.elemAt hexDigits lo);
      r = lib.trivial.fromHexString (builtins.substring 1 2 rgb);
      g = lib.trivial.fromHexString (builtins.substring 3 2 rgb);
      b = lib.trivial.fromHexString (builtins.substring 5 2 rgb);
      mean = (r + g + b) / 3.0;
      mk = orig: orig * 0.5 + mean * 0.2;
      r2 = mk r;
      g2 = mk g;
      b2 = mk b;
  in
    "#${toHex r2}${toHex g2}${toHex b2}";
in {
  site.apps.mealie.enabled = true;

  services.mealie = {
    enable = true;
    port = app.port;
    settings = {
      ALLOW_SIGNUP = "false";
      MAX_WORKERS = 1;
      WEB_CONCURRENCY = 1;
      BASE_URL = app.url;
      TOKEN_TIME = 2200;
      DB_ENGINE = "postgres";
      DATA_DIR = app.dir;
      CRF_MODEL_PATH = "${app.dir}/model.crfmodel";
      POSTGRES_URL_OVERRIDE = "postgresql://${mealie-user}:@localhost/${mealie-user}?host=/run/postgresql";
      OIDC_AUTH_ENABLED = "true";
      OIDC_AUTO_REDIRECT = "true";
      OIDC_CLIENT_ID = "mealie";
      OIDC_CONFIGURATION_URL = "${config.site.apps.authelia.url}/.well-known/openid-configuration";
      OIDC_SIGNUP_ENABLED = "true";
      OIDC_USER_GROUP = app.groups.primary;
      OIDC_ADMIN_GROUP = app.groups.admin;
      DEFAULT_GROUP = "Family";
      DEFAULT_HOUSEHOLD = "Unsorted";
      THEME_LIGHT_PRIMARY = config.site.accent.primary;
      THEME_LIGHT_SECONDARY = darkenHex config.site.accent.primary;
      THEME_DARK_PRIMARY = config.site.accent.primary;
      THEME_DARK_SECONDARY = darkenHex config.site.accent.primary;
      LOG_LEVEL = "DEBUG";
    } // (if config.site.apps.llm.enabled then {
      OPENAI_BASE_URL = "${config.site.apps.llm.url}/v1";
      OPENAI_MODEL = "llm";
      OPENAI_API_KEY_FILE = config.site.apps.llm.secrets.api-key.credentials.mealie;
      OPENAI_WORKERS = "1";
    } else {});
    credentialsFile = app.secrets.credentials-env.decrypted;
  };

  systemd.services.mealie = let
    dependencies = [ "postgresql.service" ];
  in {
    after = dependencies;
    requires = dependencies;
    serviceConfig.User = mealie-user;
    serviceConfig.DynamicUser = lib.mkForce false;
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ mealie-user ];
    ensureUsers = [
      { name = mealie-user;
        ensureDBOwnership = true;
      }
    ];
  };

  users.users.${mealie-user} = {
    group = mealie-user;
    isSystemUser = true;
  };
  users.groups.${mealie-user} = {};
}
