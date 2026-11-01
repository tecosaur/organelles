# agenix's rules, derived from the secrets each app and module declares in its site.nix
# (site.apps.<app>.secrets, its auth's clients, and site.secrets): a secret is encrypted to
# the admin and to every host, or to those it names.

let
  inherit (import ../site/manifest.nix) lib site;
  recipients = import ./recipients.nix;
in lib.mapAttrs (_: secret: {
  publicKeys = [ recipients.admin ]
    ++ map (host: recipients.hosts.${host}) (if secret.recipients == null then site.hosts else secret.recipients);
} // lib.optionalAttrs (secret.description != "") { inherit (secret) description; }) site.secret-files
