{ config, lib, site-lib, ... }:

{
  options.site.apps.sftpgo = site-lib.mkAppOption {
    health.path = "/healthz";
    name = "SFTPGo";
    homepage = "https://sftpgo.com";
    description = "SFTP server";
    subdomain = "files";
    port = 8083;
    ports = {
      sftp = { port = 2022; exposure = "public"; };
      webdav = { port = 3303; clients = [ "caddy" ]; };
    };
    admin = null;
  };
  config.site.apps.sftpgo.groups.extra = [ "family" ];
}
