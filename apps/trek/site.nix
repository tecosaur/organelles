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
  };
}
