{ config, lib, site-lib, ... }:

{
  options.site.apps.immich = site-lib.mkAppOption {
    health.path = "/api/server/ping";
    name = "Immich";
    homepage = "https://immich.app";
    guide = ./guide.html;
    description = "photo and video management";
    simpleicon = "immich";
    service = "immich-server";
    usesStateDir = false;
    subdomain = "photos";
    port = 2283;
    ports.machine-learning = { port = 3003; unit = "immich-machine-learning"; clients = [ "immich-server" ]; };
    auth = {
      policy = { };
      clients.immich = {
        redirects = [ "auth/login" "user-settings" "app.immich:///oauth-callback" ];
        pkce = false;
        settings.token_endpoint_auth_method = "client_secret_post";
      };
    };
    mail = { sender = "noreply"; units = [ "immich-server" ]; };
  };
}
