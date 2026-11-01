{ config, lib, ... }:

# Authelia's OIDC policies and clients, and its forward-auth rules, from each enabled app's auth

let
  inherit (config.site) domain;
  apps = lib.filterAttrs (_: app: app.enabled) config.site.apps;
  id-of = app: lib.toLower (lib.replaceStrings [ " " ] [ "-" ] app.name);
  digest = id: lib.removeSuffix "\n" (builtins.readFile (../../secrets/oidc + "/${id}-hash.txt"));
  policy = app: let
    inherit (app.auth.policy) users admins;
    admin-group = lib.optional (app.groups.admin != null) "group:${app.groups.admin}";
    user-groups = [ "group:${app.groups.primary}" ] ++ map (group: "group:${group}") app.groups.extra;
  in {
    default_policy = "deny";
    rules = if users == admins
      then [ { policy = users; subject = admin-group ++ user-groups; } ]
      else [ { policy = users; subject = user-groups; } ]
        ++ lib.optional (app.groups.admin != null) { policy = admins; subject = "group:${app.groups.admin}"; };
  };
  client = app: id: client: {
    client_id = id;
    client_name = if id == id-of app then app.name else id;
    authorization_policy = id-of app;
    client_secret = digest id;
    public = false;
    consent_mode = "implicit";
    require_pkce = client.pkce;
    pkce_challenge_method = if client.pkce then "S256" else "";
    redirect_uris = map (redirect: if lib.hasInfix "://" redirect then redirect
      else "${app.url}/${redirect}") client.redirects;
    scopes = [ "openid" "email" "profile" "groups" ];
    access_token_signed_response_alg = "none";
    response_types = [ "code" ];
    grant_types = [ "authorization_code" ];
    userinfo_signed_response_alg = "none";
    token_endpoint_auth_method = "client_secret_basic";
  } // client.settings;
  access = app: let inherit (app.auth.access) policy subject; in [
    { inherit (app) domain; inherit policy;
      subject = if subject != null then subject else [ "group:${app.groups.primary}" "group:${app.groups.admin}" ]; }
    { inherit (app) domain; policy = "deny"; }
  ];
in {
  services.authelia.instances.main.settings = {
    identity_providers.oidc = {
      authorization_policies = lib.mapAttrs' (_: app: lib.nameValuePair (id-of app) (policy app))
        (lib.filterAttrs (_: app: app.auth.policy != null) apps);
      clients = lib.concatLists (lib.mapAttrsToList (_: app: lib.mapAttrsToList (client app) app.auth.clients) apps);
    };
    access_control.rules = [ { inherit domain; policy = "one_factor"; } ]
      ++ lib.concatLists (lib.mapAttrsToList (_: access) (lib.filterAttrs (_: app: app.auth.access != null) apps));
  };
}
