{ config, lib, site-lib, ... }:

{
  options.site.apps.sftpgo = site-lib.mkAppOption {
    health.path = "/healthz";
    name = "SFTPGo";
    homepage = "https://sftpgo.com";
    guide = ./guide.html;
    description = "SFTP server";
    subdomain = "files";
    port = 8083;
    branding = {
      "/static/img/*" = "sftpgo/";
      "/static/favicon.png" = "sftpgo/favicon.png";
    };
    ports = {
      sftp = { port = 2022; exposure = "public"; };
      webdav = { port = 3303; clients = [ "caddy" ]; };
    };
    admin = null;
    auth = {
      policy = { };
      clients.sftpgo = {
        redirects = [ "web/oidc/redirect" "web/oauth2/redirect" ];
        secret.units = [ "sftpgo" ];
        pkce = false;
        settings.token_endpoint_auth_method = "client_secret_post";
      };
    };
    secrets = {
      admin-password = { kind = "password"; description = "SFTPGo admin login"; units = [ "sftpgo" ]; };
    };
  };
}
