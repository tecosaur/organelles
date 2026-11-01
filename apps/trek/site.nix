{ config, lib, site-lib, ... }:

{
  options.site.apps.trek = site-lib.mkAppOption {
    health.path = "/api/health";
    name = "Trek";
    homepage = "https://github.com/liketrek/TREK";
    description = "collaborative travel planner";
    subdomain = "travel";
    port = 8054;
    # The rest of the state directory is a tree of links to the store,
    # rebuilt on every start.
    stateSubdirs = [ "data" "uploads" ];
    auth = {
      policy = { };
      clients.trek = {
        redirects = [ "api/auth/oidc/callback" ];
        settings.token_endpoint_auth_method = "client_secret_post";
      };
    };
    secrets = {
      aerodatabox-key = { kind = "credential"; description = "AeroDataBox RapidAPI key, for TREK flight tracking"; };
      maps-key = { kind = "credential"; description = "Google Maps API key, for TREK place search"; };
      mapbox-token = { kind = "credential"; description = "Mapbox access token (pk....), for TREK maps"; };
      unsplash-key = { kind = "credential"; description = "Unsplash access key, for TREK trip covers"; };
    };
  };
}
