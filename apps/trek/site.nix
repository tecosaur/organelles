{ config, lib, site-lib, ... }:

{
  options.site.apps.trek = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Trek";
    homepage = "https://github.com/liketrek/TREK";
    description = "collaborative travel planner";
    subdomain = "travel";
    port = 8054;
    # listed, not globbed: TREK serves its own /icons too
    branding = {
      "/icons/icon.svg" = "trek/icons/icon.svg";
      "/icons/icon-192x192.png" = "trek/icons/icon-192x192.png";
      "/icons/icon-512x512.png" = "trek/icons/icon-512x512.png";
      "/icons/apple-touch-icon-180x180.png" = "trek/icons/apple-touch-icon-180x180.png";
    };
    # The rest of the state directory is a tree of links to the store,
    # rebuilt on every start.
    stateSubdirs = [ "data" "uploads" ];
    auth = {
      policy = { };
      clients.trek = {
        redirects = [ "api/auth/oidc/callback" ];
        settings.token_endpoint_auth_method = "client_secret_post";
        secret.units = [ "trek" ];
      };
    };
    secrets = {
      aerodatabox-key = { kind = "credential"; description = "AeroDataBox RapidAPI key, for TREK flight tracking"; units = [ "trek" ]; };
      maps-key = { kind = "credential"; description = "Google Maps API key, for TREK place search"; units = [ "trek" ]; };
      mapbox-token = { kind = "credential"; description = "Mapbox access token (pk....), for TREK maps"; units = [ "trek" ]; };
      unsplash-key = { kind = "credential"; description = "Unsplash access key, for TREK trip covers"; units = [ "trek" ]; };
    };
  };
}
