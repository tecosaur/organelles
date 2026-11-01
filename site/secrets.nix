{ config, lib, site-lib, ... }:

# Every secret the site holds, declared by what holds it: an app in site.apps.<app>.secrets,
# its OIDC clients through its auth, and anything else in site.secrets. secrets/secrets.nix
# and the scripts in secrets/scripts derive agenix's rules and what to create from the
# resolved site.secret-files.

let
  app-secrets = lib.concatLists (lib.mapAttrsToList (_: app:
    lib.attrValues app.secrets
    ++ lib.mapAttrsToList (id: client: {
      kind = "oidc";
      generate = null;
      description = "${app.name}'s OIDC client secret";
      optional = false;
      recipients = null;
      path = "oidc/${id}-secret.age";
      inherit (client) file;
    }) (lib.filterAttrs (_: client: client.holds-secret) app.auth.clients))
    config.site.apps);
in {
  options.site = {
    secrets = lib.mkOption {
      type = lib.types.attrsOf (site-lib.secret { });
      default = { };
      description = "The secrets that belong to no app, by file name";
    };
    secret-files = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      readOnly = true;
      default = lib.listToAttrs (map (secret: lib.nameValuePair secret.path secret)
        (lib.attrValues config.site.secrets ++ app-secrets));
      description = ''
        Every secret, its apps' and the site's alike, by its path under
        secrets/: what agenix's rules, the scripts and checks read, and how
        code spanning several apps finds one by file.
      '';
    };
  };
}
