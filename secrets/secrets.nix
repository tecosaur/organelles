let
  base = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZZqcJOLdN+QFHKyW8ST2zz750+8TdvO9IT5geXpQVt tec@tranquillity";
  golgi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEEmWE6y+gkNdOdgooahbgalxguyoPos7dKCAeVzokm/ root@golgi";
  nucleus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOeDXHlRp0k18hSszwUYw+5FiNbPE+XLxRdXSqUUdYOF root@nucleus";
  centrosome = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEw37nXVPIzAHyO07o2+w/M5GbCCdqqTPRBXZFunsb1U root@centrosome";
  all = [ base golgi nucleus centrosome ];
in
{
  # Paired with the `*-hash.txt` digests; both written by `make-oidc.sh`.
  "oidc/beszel-secret.age".publicKeys = all;
  "oidc/dawarich-secret.age".publicKeys = all;
  "oidc/headplane-secret.age".publicKeys = all;
  "oidc/headscale-secret.age".publicKeys = all;
  "oidc/immich-secret.age".publicKeys = all;
  "oidc/jellyfin-secret.age".publicKeys = all;
  "oidc/memos-secret.age".publicKeys = all;
  "oidc/paperless-secret.age".publicKeys = all;
  "oidc/rustical-secret.age".publicKeys = all;
  "oidc/sftpgo-secret.age".publicKeys = all;
  "oidc/storyteller-secret.age".publicKeys = all;
  "oidc/tandoor-secret.age".publicKeys = all;
  "oidc/trek-secret.age".publicKeys = all;
  "oidc/vikunja-secret.age".publicKeys = all;
  "oidc/warracker-secret.age".publicKeys = all;
  "oidc/windmill-secret.age".publicKeys = all;

  # Set by hand: from a third party, or from a service that alone can mint it.
  "credentials/beszel-token.age" = { publicKeys = all; description = "Beszel hub token"; };
  "credentials/bunny-dns-key.age" = { publicKeys = all; description = "Bunny API key, for dns-pooler; it also keys the peer channel, so every node needs the same one"; };
  "credentials/cloudflare-api-env.age" = { publicKeys = all; description = "Cloudflare API token, as CLOUDFLARE_API_TOKEN=..."; };
  "credentials/deezer-arl.age" = { publicKeys = all; description = "Deezer arl login cookie, for multi-scrobbler"; };
  "credentials/listenbrainz-token.age" = { publicKeys = all; description = "ListenBrainz user token, for multi-scrobbler"; };
  "credentials/crowdsec-enroll-key.age" = { publicKeys = all; description = "CrowdSec console enrolment key"; };
  "credentials/fastmail.age" = { publicKeys = all; description = "Fastmail app password, for SMTP"; };
  "credentials/hardcover-token.age" = { publicKeys = all; description = "Hardcover API token, for Storyteller metadata import"; };
  "credentials/home-assistant-secrets.age" = { publicKeys = all; description = "Home Assistant secrets.yaml"; };
  "credentials/mealie-credentials-env.age" = { publicKeys = all; description = "Mealie OIDC/SMTP environment"; };
  "credentials/ntfy-webpush-keys-env.age" = { publicKeys = all; description = "ntfy web push keys"; };
  "credentials/tailscale-preauth.age" = { publicKeys = all; description = "Tailscale pre-auth key"; };
  "credentials/tandoor-fdc-api-key.age" = { publicKeys = all; description = "USDA FoodData Central API key"; };
  "credentials/trek-aerodatabox-key.age" = { publicKeys = all; description = "AeroDataBox RapidAPI key, for TREK flight tracking"; };
  "credentials/trek-maps-key.age" = { publicKeys = all; description = "Google Maps API key, for TREK place search"; };
  "credentials/trek-mapbox-token.age" = { publicKeys = all; description = "Mapbox access token (pk....), for TREK maps"; };
  "credentials/trek-unsplash-key.age" = { publicKeys = all; description = "Unsplash access key, for TREK trip covers"; };

  "passwords/llm-api-key.age" = { publicKeys = all; description = "Shared secret between the llama-server and its clients"; };
  "passwords/koito-admin-password.age" = { publicKeys = all; description = "Koito admin login"; };
  "passwords/multi-scrobbler-endpoint-token.age" = { publicKeys = all; description = "Token Lyrion's AudioScrobbler plugin presents to multi-scrobbler's ListenBrainz endpoint"; };
  "passwords/lldap-admin-password.age" = { publicKeys = all; description = "LLDAP admin login, used at its web UI"; };
  "passwords/paperless-admin-password.age" = { publicKeys = all; description = "Paperless admin login"; };
  "passwords/sftpgo-admin-password.age" = { publicKeys = all; description = "SFTPGo admin login"; };

  # Every node running the auth stack must hold the same key material to
  # accept the others' tokens.
  "keys/authelia-jwt.age".publicKeys = all;
  "keys/authelia-oidc-hmac.age".publicKeys = all;
  "keys/authelia-oidc-issuer.pem.age".publicKeys = all;
  "keys/authelia-session.age".publicKeys = all;
  "keys/authelia-storage.age".publicKeys = all;
  "keys/gatus-push.age".publicKeys = all;
  "keys/lldap-jwt.age".publicKeys = all;
  "keys/lldap-key-seed.age".publicKeys = all;
  "keys/meilisearch-master.age".publicKeys = all;
  "keys/multi-scrobbler-jellyfin.age".publicKeys = all;
  "keys/multi-scrobbler-koito.age".publicKeys = all;
  "keys/postgresql-ha-replication.age".publicKeys = all;
  "keys/status-alert-topic.age".publicKeys = all;
  "keys/trek-encryption.age".publicKeys = all;
  "keys/valkey-ha.age".publicKeys = all;
  "keys/wg-centrosome.age".publicKeys = [ base centrosome ];
  "keys/wg-golgi.age".publicKeys = [ base golgi ];
  "keys/wg-nucleus.age".publicKeys = [ base nucleus ];
}
