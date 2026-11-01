# agenix's rules, from the declared secrets: each is encrypted to the admin and its recipients

let
  inherit (import ../site/manifest.nix) lib site;
  recipients = import ./recipients.nix;
in lib.mapAttrs (_: secret: {
  publicKeys = [ recipients.admin ]
    ++ map (host: recipients.hosts.${host}) (if secret.recipients == null then site.hosts else secret.recipients);
} // lib.optionalAttrs (secret.description != "") { inherit (secret) description; }) site.secret-files
