{ config, options, lib, site-lib, ... }:

let
  inherit (lib) types mkOption;
  # Lowercase and quote-free, so values drop straight into Stalwart's and Authelia's expressions
  login = types.strMatching "[a-z0-9][a-z0-9_-]*";
  capacities = description: mkOption { type = types.attrsOf types.ints.positive; inherit description; };
  domain.options = {
    users = mkOption {
      type = types.listOf login;
      default = [ ];
      description = "Logins with addresses here, known at evaluation";
    };
    group = mkOption {
      type = types.nullOr (types.strMatching "[A-Za-z0-9_.-]+");
      default = null;
      description = "An LLDAP group whose members are users here too, as of their sign-in";
    };
    addresses = mkOption {
      type = types.nonEmptyListOf (types.strMatching "[a-z0-9._+{}-]+@[a-z0-9.{}-]+");
      default = [ "{user}@{domain}" ];
      description = ''
        Each user's addresses, as templates over {user} and {domain}. A
        user's canonical address, which names their account, is the first
        template of the first domain (alphabetically) listing them in
        `users`, else of the first whose `group` holds them. Group members
        not listed in any `users` get only that address.
      '';
    };
    filing = mkOption {
      type = types.nullOr (types.enum [ "{location}@{user}.{domain}" ]);
      default = null;
      description = ''
        Where mail is addressed to be filed into a folder of a user with
        {user}@{domain}, or null for no filing. Their account files it into
        the deepest existing folder of the location's first three
        dot-separated parts, else the inbox, as it does {user}+{location}@{domain}.
        Group members' accounts have no Sieve stub, so their mail is not filed.
      '';
    };
    catch-all = mkOption {
      type = types.nullOr login;
      default = null;
      description = "A user listed in some domain's `users` who receives every other address here";
    };
    catch-subdomains = mkOption {
      type = types.nullOr login;
      default = null;
      description = ''
        A user listed in some domain's `users` who receives mail to any
        subdomain that no mail domain or filing address handles.
      '';
    };
  };
in {
  options.site.apps.mail = site-lib.mkAppOption {
    name = "Mail";
    homepage = "https://stalw.art";
    description = "mail server and web client";
    service = "stalwart";
    # its state lives in the replicated Postgres instance and the blob store
    usesStateDir = false;
    subdomain = "mail";
    port = 8460;
    proxy = false;
    # each query of Stalwart's goes to the primary, so a request had best go beside it
    prefersPrimary = true;
    branding = {
      "/favicon.ico" = "mail/stalwart/favicon.ico";
      "/admin/favicon.ico" = "mail/stalwart/favicon.ico";
      "/account/favicon.ico" = "mail/stalwart/favicon.ico";
      "/branding/Bulwark_Favicon.svg" = "mail/bulwark/favicon.svg";
      "/branding/Bulwark_Logo_Color.svg" = "mail/bulwark/favicon.svg";
      "/branding/Bulwark_Logo_White.svg" = "mail/bulwark/favicon.svg";
      "/apple-touch-icon.png" = "mail/bulwark/apple-touch-icon.png";
      "/icon-*.png" = "mail/bulwark/";
    };
    ports = let
      inherit (config.site.mail.storage) heads;
      cluster-hosts = cluster: lib.attrNames config.site.mail.storage.${cluster};
      setup = cluster: { garage-mail-setup = [ heads.${cluster} ]; };
      s3 = cluster: port: {
        inherit port;
        unit = "garage";
        hosts = [ heads.${cluster} ];
        exposure = "mesh";
        clients = setup cluster // { s3-overflow = config.site.apps.mail.hosts; };
      };
      rpc = cluster: port: {
        inherit port;
        unit = "garage";
        hosts = cluster-hosts cluster;
        exposure = if lib.length (cluster-hosts cluster) > 1 then "mesh" else "local";
        clients = setup cluster // { garage = cluster-hosts cluster; };
      };
    in lib.mapAttrs (_: port: { inherit port; exposure = "public"; })
      { smtp = 25; submissions = 465; submission = 587; imaps = 993; sieve = 4190; }
    // {
      bulwark = { port = 3480; unit = "bulwark"; clients = [ "caddy" ]; };
      submission-mesh = { port = 10588; exposure = "mesh"; clients.caddy = config.site.hosts; };
      submission-local = {
        port = 10587;
        unit = "caddy";
        hosts = config.site.hosts;
        clients = lib.zipAttrsWith (_: hosts: lib.unique (lib.concatLists hosts))
          (lib.mapAttrsToList (_: app: lib.genAttrs app.mail.units (_: app.hosts))
            (lib.filterAttrs (_: app: app.mail != null && app.mail.sender != null) config.site.apps));
      };
      stalwart-recovery.port = 8461;
      s3-gateway = { port = 3920; unit = "s3-overflow"; clients = [ "stalwart" ]; };
      s3-gateway-status = { port = 3921; unit = "s3-overflow"; clients = [ "gatus-aggregator-report" ]; };
      garage-primary-s3 = s3 "primary" 3900;
      garage-primary-rpc = rpc "primary" 3901;
      garage-overflow-s3 = s3 "overflow" 3910;
      garage-overflow-rpc = rpc "overflow" 3911;
    };
    health = {
      path = "/healthz/ready";
      ports = [ { listener = "smtp"; } { listener = "imaps"; tls = true; } ];
    };
    auth.clients = let
      inherit (config.site.mail) oidc;
      # SUPPORTED_LOCALES in Bulwark 1.14.2's i18n/routing.ts; its redirect is /<locale>/auth/callback
      bulwark-locales = [ "ar" "ca" "cs" "da" "de" "en" "es" "fa" "fr" "he" "hu" "it" "ja" "ko"
                          "lv" "mn" "nb" "nl" "pl" "pt" "ro" "ru" "sk" "tr" "uk" "zh" "zh-TW" ];
      stalwart-client = settings: {
        authorization_policy = oidc.authorization-policy;
        claims_policy = oidc.claims-policy;
        audience = [ oidc.audience ];
        requested_audience_mode = "implicit";
        access_token_signed_response_alg = "RS256";
      } // settings;
    in {
      ${oidc.bulwark-client} = {
        redirects = map (locale: "${locale}/auth/callback") bulwark-locales;
        secret.units = [ "bulwark" ];
        settings = stalwart-client {
          scopes = [ "openid" "profile" oidc.account-claim "offline_access" ];
          grant_types = [ "authorization_code" "refresh_token" ];
          inherit (oidc) lifespan;
          token_endpoint_auth_method = "client_secret_post";
          # It revokes tokens at sign-out as it fetches them, and the default differs
          revocation_endpoint_auth_method = "client_secret_post";
        };
      };
      ${oidc.web-ui-client} = {
        redirects = [ "admin/oauth/callback" "account/oauth/callback" ];
        secret = null;
        settings = stalwart-client {
          client_secret = "";
          public = true;
          # Authelia discourages implicit consent for public clients
          consent_mode = "pre-configured";
          scopes = [ "openid" "profile" oidc.account-claim ];
          token_endpoint_auth_method = "none";
        };
      };
    };
    # files named for what holds them, not the app
    # Stalwart and the gateway run where the primary may
    secrets = let
      stalwart.stalwart = config.site.ha.preference;
      gateway.s3-overflow = config.site.ha.preference;
    in lib.mapAttrs (name: secret: secret // { file-name = name; }) ({
      bulwark-session = { kind = "key"; generate = "rand"; units = [ "bulwark" ]; };
      s3-overflow-client = { kind = "key"; generate = "s3-key"; units = stalwart // gateway; };
      meilisearch-stalwart = { kind = "key"; generate = "meilisearch"; units = stalwart; };
      valkey-stalwart = { kind = "key"; generate = "rand"; units = { valkey-ha = config.site.ha.members; } // stalwart; };
      valkey-s3-overflow = { kind = "key"; generate = "rand"; units = { valkey-ha = config.site.ha.members; } // gateway; };
    } // lib.optionalAttrs (config.site.mail.relay != null) {
      stalwart-relay = { kind = "credential"; description = "Stalwart's password at its relay, ${config.site.mail.relay.host}"; units = stalwart; };
    } // (let
      inherit (config.site.mail) addressing storage;
      clusters = { inherit (storage) primary overflow; };
      meshed = lib.filterAttrs (_: capacity: lib.length (lib.attrNames capacity) > 1) clusters;
    in lib.listToAttrs (
      map (domain: lib.nameValuePair "dkim-${domain.name}" { kind = "key"; generate = "dkim"; units = stalwart; })
        (lib.filter (domain: domain.signs) addressing.domains)
      ++ lib.mapAttrsToList (cluster: _: lib.nameValuePair "garage-mail-${cluster}" {
        kind = "key"; generate = "s3-key"; units = { garage-mail-setup = [ storage.heads.${cluster} ]; } // gateway;
      }) clusters
      # Garage refuses a secret its owner alone cannot read, so not systemd's 0440 credential copy
      ++ lib.mapAttrsToList (cluster: capacity: lib.nameValuePair "garage-${cluster}-rpc" {
        kind = "key"; generate = "hex"; owner = "garage"; hosts = lib.attrNames capacity;
      }) meshed
      ++ lib.concatLists (lib.mapAttrsToList (_: capacity: map (host: lib.nameValuePair "garage-node-${host}" {
        kind = "key"; generate = "garage-node"; recipients = [ host ]; units.garage = [ host ];
      }) (lib.attrNames capacity)) meshed))));
  };
  options.site.mail = {
    domains = mkOption {
      type = types.attrsOf (types.submodule domain);
      default = { };
      example = { "example.org" = { users = [ "alice" ]; catch-all = "alice"; }; };
      description = "The domains Stalwart hosts, by name, and who has mail there";
    };
    admins = mkOption {
      type = types.listOf login;
      default = [ ];
      description = ''
        Logins whose accounts administer the mail server. A group member's
        account gets the role at the first start after their first sign-in.
      '';
    };
    addressing = mkOption {
      type = types.attrs;
      readOnly = true;
      default = import ./addressing.nix { inherit lib; } { inherit (config.site.mail) domains admins; };
      defaultText = lib.literalMD "addressing.nix's model of `domains` and `admins`";
      description = "The accounts, domains and sign-in rules Stalwart and Authelia are configured from";
    };
    contact = mkOption {
      type = types.str;
      default = "admin@${config.site.domain}";
      defaultText = lib.literalExpression ''"admin@''${config.site.domain}"'';
      description = ''
        Where mail to an app's noreply@<subdomain> address is pointed: the
        refusal of anything but a reply names it, and a reply is answered
        with it.
      '';
    };
    oidc = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      default = {
        audience = config.site.apps.mail.url;
        issuer = config.site.apps.authelia.url;
        account-claim = "mail_account";
        claims-policy = "mail";
        authorization-policy = "mail";
        web-ui-client = "stalwart-webui";
        bulwark-client = "bulwark";
        lifespan = "mail";
      };
      description = ''
        What the mail clients share in Authelia: the access-token `audience`
        (Stalwart's `acceptedAudiences`), Authelia's `issuer` URL, the
        `account-claim` naming each user's account (also its scope and user
        attribute), the names of the claims policy, authorization policy and
        token lifespan they use, and the client ids of Stalwart's own WebUI and
        of Bulwark.
      '';
    };
    relay = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          host = mkOption {
            type = types.str;
            example = "mail.smtp2go.com";
            description = "The relay's host name";
          };
          port = mkOption {
            type = types.port;
            default = 587;
            description = "The relay's submission port: 465 for implicit TLS, otherwise STARTTLS";
          };
          username = mkOption {
            type = types.str;
            description = "The user Stalwart authenticates to the relay as";
          };
          spf = mkOption {
            type = types.str;
            example = "include:spf.smtp2go.com";
            description = "The SPF mechanism that authorises the relay to send for the domain";
          };
          records = mkOption {
            inherit (options.site.dns.records) type;
            default = [ ];
            example = [ { name = "em123456"; type = "CNAME"; value = "return.smtp2go.net."; } ];
            description = "The relay's verification and return-path records, as its provider gives them";
          };
        };
      });
      default = null;
      description = ''
        The smarthost all outbound mail goes through, or null to deliver
        directly. Its password is secrets/credentials/stalwart-relay.age.
      '';
    };
    connections = mkOption {
      type = types.attrsOf types.attrs;
      readOnly = true;
      default = lib.mapAttrs (name: app:
        if (app.mail.sender != null) == (app.mail.smtp != null)
        then throw "site.apps.${name}.mail: give either sender, to send through the site's Stalwart, or smtp and from, to send through another server"
        else if app.mail.sender != null then {
          host = "127.0.0.1";
          port = config.site.apps.mail.ports.submission-local.port;
          security = "none";
          from = "${app.mail.sender}@${app.domain}";
          inherit (app.mail) reply-to;
        } else {
          inherit (app.mail.smtp) host port security username;
          inherit (app.mail) from reply-to;
          password = app.secrets.smtp.credential;
        }) (lib.filterAttrs (_: app: app.mail != null) config.site.apps);
      description = ''
        Each sending app's connection: { host; port; security; from; reply-to; },
        and through another server also { username; password; }, the password
        a credential path in its unit. reply-to may be null.
      '';
    };
    dkim = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      readOnly = true;
      description = ''
        Each sending domain's DKIM `selector`, and the TXT `record` to publish
        at <selector>._domainkey.<domain>.
      '';
    };
    storage = {
      primary = capacities "The primary Garage's hosts, by the bytes each offers. Each holds every blob.";
      overflow = capacities ''
        The overflow Garage's hosts, by the bytes each offers, holding what the
        primary cannot take while it is down. Each holds every such blob.
      '';
      overflow-quota-bytes = mkOption {
        type = types.ints.positive;
        description = "The most the overflow bucket holds";
      };
      heads = mkOption {
        type = types.attrsOf types.str;
        readOnly = true;
        default = lib.mapAttrs (_: capacity-bytes:
          lib.findFirst (host: capacity-bytes ? ${host}) (lib.head (lib.attrNames capacity-bytes)) config.site.ha.preference)
          { inherit (config.site.mail.storage) primary overflow; };
        description = "Each cluster's head, which serves its S3 to the mesh and applies layouts: the member likeliest to run a gateway";
      };
      cache-bytes = mkOption {
        type = types.attrsOf types.ints.positive;
        default = { };
        description = "The hosts whose gateway caches blobs, by the bytes each cache aims for";
      };
    };
  };
  config.site = let hosts = config.site.ha.preference; in {
    ports = {
      ha-postgres.clients = { stalwart = hosts; s3-overflow = hosts; };
      ha-valkey.clients = { stalwart = hosts; s3-overflow = hosts; };
      meilisearch.clients.stalwart = hosts;
    };
    secrets = {
      valkey-ha.units = { stalwart = hosts; s3-overflow = hosts; };
      bunny-dns-key.units.stalwart = hosts;
    };
  };
}
