{ config, lib, site-lib, ... }:

# Every secret the site holds, declared by what holds it: an app in site.apps.<app>.secrets,
# its OIDC clients' in their auth, and anything else in site.secrets. secrets/secrets.nix and
# the scripts in secrets/scripts read the resolved site.secret-files. Each is installed on
# its hosts: decrypted once, root's alone unless it names an owner, and loaded by each of its
# units as a credential.

let
  this-host = config.site.server.host;
  # each secret with the hosts that hold it by default: its units', else those it is encrypted
  # to, else its app's
  app-secrets = lib.concatLists (lib.mapAttrsToList (_: app: map (secret: { inherit secret; default-hosts = app.hosts; })
    (lib.attrValues app.secrets
     ++ lib.filter (secret: secret != null) (lib.mapAttrsToList (_: client: client.secret) app.auth.clients)))
    config.site.apps);
  site-secrets = map (secret: { inherit secret; default-hosts = config.site.hosts; }) (lib.attrValues config.site.secrets);
  all-secrets = app-secrets ++ site-secrets;
  hosts-of = { secret, default-hosts }:
    if secret.hosts != null then secret.hosts
    else if lib.isAttrs secret.units then lib.unique (lib.concatLists (lib.attrValues secret.units))
    else if secret.recipients != null then secret.recipients
    else default-hosts;
  # an optional secret whose file is missing turns off what uses it, so it is not installed
  installed = map (entry: entry.secret) (lib.filter (entry:
      lib.elem this-host (hosts-of entry)
      && (!entry.secret.optional || builtins.pathExists entry.secret.file))
    all-secrets);
  # the units here that read a secret
  units-here = secret: if lib.isList secret.units then secret.units
    else lib.attrNames (lib.filterAttrs (_: hosts: lib.elem this-host hosts) secret.units);
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
      default = lib.listToAttrs (map ({ secret, ... }: lib.nameValuePair secret.path secret) all-secrets);
      description = ''
        Every secret, its apps' and the site's alike, by its path under
        secrets/: what agenix's rules, the scripts and checks read, and how
        code spanning several apps finds one by file.
      '';
    };
  };

  config = {
    age.secrets = lib.listToAttrs (map (secret: lib.nameValuePair secret.file-name {
      inherit (secret) file owner group mode;
    }) installed);

    systemd.services = lib.mkMerge (lib.concatMap (secret: map (unit: {
      ${unit}.serviceConfig.LoadCredential = [ "${secret.credential-name}:${secret.decrypted}" ];
    }) (units-here secret)) installed);

    assertions = lib.concatMap (secret: map (unit: {
      assertion = let service = config.systemd.services.${unit}; in
        service.script != "" || service.serviceConfig ? ExecStart;
      message = "site: secrets/${secret.path} is loaded on ${this-host} by ${unit}, which runs no service here; "
        + "name the hosts each of its units runs on";
    }) (units-here secret)) installed
    ++ lib.mapAttrsToList (key: secrets: {
      assertion = lib.length secrets == 1;
      message = let unit = lib.head (lib.splitString ":" key); in
        "site: ${unit} on ${this-host} loads ${lib.concatMapStringsSep " and " (secret: "secrets/${secret.path}") secrets} "
        + "under one credential name, its secret's; rename one, keeping its file with file-name";
    }) (lib.groupBy (secret: "${secret.unit}:${secret.credential-name}")
      (lib.concatMap (secret: map (unit: secret // { inherit unit; }) (units-here secret)) installed));
  };
}
