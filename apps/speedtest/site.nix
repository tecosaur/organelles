{ config, lib, site-lib, ... }:

{
  options.site.apps.speedtest = site-lib.mkAppOption {
    health.path = "/backend/empty";
    name = "Speedtest";
    homepage = "https://github.com/librespeed/speedtest";
    description = "connection speed testing";
    service = "librespeed";
    usesStateDir = false;
    subdomain = "speed";
    port = 8076;
  };
}
