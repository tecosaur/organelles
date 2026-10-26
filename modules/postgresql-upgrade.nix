{ config, lib, pkgs, ... }:

# The NixOS manual's upgrade-pg-cluster, installed while
# services.postgresql.upgradeTo names a newer major. Run it once as root
# with every database client stopped, then pin the package to the target.
# The new cluster takes the old one's locale, encoding and checksum
# setting, which pg_upgrade requires to match, and the same extensions;
# preloaded libraries (VectorChord) are loaded on both sides, without
# which pg_upgrade cannot check them.

let
  cfg = config.services.postgresql;
  newPostgres = cfg.upgradeTo.withPackages cfg.extensions;
  preload = cfg.settings.shared_preload_libraries or null;
  preloadOpts = lib.optionalString (preload != null) (let
    libs = if lib.isList preload then lib.concatStringsSep "," preload else preload;
    opt = lib.escapeShellArg "-c shared_preload_libraries=${libs}";
  in "-O ${opt} -o ${opt}");
in {
  options.services.postgresql.upgradeTo = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    example = lib.literalExpression "pkgs.postgresql_18";
    description = "Postgres major to install upgrade-pg-cluster for; null installs nothing.";
  };

  config = lib.mkIf (cfg.upgradeTo != null) {
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "upgrade-pg-cluster" ''
        set -eux
        OLDDATA="${cfg.dataDir}" OLDBIN="${cfg.finalPackage}/bin"
        NEWDATA="/var/lib/postgresql/${newPostgres.psqlSchema}" NEWBIN="${newPostgres}/bin"
        template=$(runuser -u postgres -- "$OLDBIN/psql" -tA -F ' ' -c \
          "select datcollate, datctype, pg_encoding_to_char(encoding) from pg_database where datname = 'template1'")
        read -r collate ctype encoding <<< "$template"
        systemctl stop postgresql
        checksums=--data-checksums
        if runuser -u postgres -- "$OLDBIN/pg_controldata" "$OLDDATA" | grep -q 'checksum version: *0$'; then
          checksums=--no-data-checksums
        fi
        install -d -m 0700 -o postgres -g postgres "$NEWDATA"
        cd "$NEWDATA"
        runuser -u postgres -- "$NEWBIN/initdb" -D "$NEWDATA" --encoding="$encoding" \
          --lc-collate="$collate" --lc-ctype="$ctype" "$checksums" ${lib.escapeShellArgs cfg.initdbArgs}
        runuser -u postgres -- "$NEWBIN/pg_upgrade" \
          --old-datadir "$OLDDATA" --new-datadir "$NEWDATA" \
          --old-bindir "$OLDBIN" --new-bindir "$NEWBIN" ${preloadOpts} "$@"
      '')
    ];
  };
}
