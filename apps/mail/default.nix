# Mail: its options and the site's values in site.nix; who has which address in addressing.nix;
# Stalwart, its Authelia sign-in and its DNS records in stalwart.nix, its settings in
# stalwart-settings.nix; the web client in bulwark.nix; blobs in garage.nix and s3-overflow.nix.
# Search is in the shared Meilisearch.

{
  imports = [ ./bulwark.nix ./garage.nix ./s3-overflow.nix ./stalwart.nix ./submission.nix ];
}
