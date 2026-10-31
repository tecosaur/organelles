{ config, options, lib, site-lib, ... }:

let
  inherit (lib) types mkOption;
  auth-domain = "${config.site.apps.authelia.subdomain}.${config.site.domain}";
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
    # for the other hosts' Caddy alone, since it trusts X-Forwarded-For
    exposure = "mesh";
    # its provisioner calls the management API
    clients = [ "stalwart" ];
    ports = let
      inherit (config.site.mail.storage) heads;
      cluster-hosts = cluster: lib.attrNames config.site.mail.storage.${cluster};
      # the head sets up its cluster
      setup = cluster: { garage-mail-setup = [ heads.${cluster} ]; };
      s3 = cluster: port: {
        inherit port;
        unit = "garage";
        hosts = [ heads.${cluster} ];
        exposure = "mesh";
        clients = setup cluster // { s3-overflow = config.site.apps.mail.hosts; };
      };
      # a lone node keeps its RPC to itself
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
      # applies the settings before each start
      stalwart-recovery = { port = 8461; clients = [ "stalwart" ]; };
      s3-gateway = { port = 3920; unit = "s3-overflow"; clients = [ "stalwart" ]; };
      s3-gateway-status = { port = 3921; unit = "s3-overflow"; clients = [ "gatus-aggregator-report" ]; };
      garage-primary-s3 = s3 "primary" 3900;
      garage-primary-rpc = rpc "primary" 3901;
      garage-overflow-s3 = s3 "overflow" 3910;
      garage-overflow-rpc = rpc "overflow" 3911;
    };
    health.ports = [ { listener = "smtp"; } { listener = "imaps"; tls = true; } ];
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
    oidc = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      default = {
        audience = "https://${config.site.apps.mail.subdomain}.${config.site.domain}";
        issuer = "https://${auth-domain}";
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
          credential-file = mkOption {
            type = types.path;
            description = "The age file of the relay's password";
          };
        };
      });
      default = null;
      description = "The smarthost all outbound mail goes through, or null to deliver directly";
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
    smtp2go.records = mkOption {
      inherit (options.site.dns.records) type;
      default = [ ];
      example = [ { name = "em123456"; type = "CNAME"; value = "return.smtp2go.net."; } ];
      description = "SMTP2GO's verification and return-path records, as its dashboard gives them";
    };
  };
  config.site.mail = {
    domains."tecosaur.net" = {
      users = [ "tec" ];
      addresses = [ "{user}@{domain}" ];
      filing = "{location}@{user}.{domain}";
      catch-all = "tec";
      catch-subdomains = "tec";
    };
    admins = [ "tec" ];
    # Bodies live on nucleus's bulk volume, and spill to the light nodes while it is down
    storage = {
      primary = { nucleus = 1000000000000; };
      overflow = { golgi = 10000000000; centrosome = 10000000000; };
      overflow-quota-bytes = 2000000000;
      cache-bytes = { golgi = 4000000000; };
    };
    smtp2go.records = [
      { name = "mailbounces"; type = "CNAME"; value = "return.smtp2go.net."; }
      { name = "s766060._domainkey"; type = "CNAME"; value = "dkim.smtp2go.net."; }
      { name = "mailtrack"; type = "CNAME"; value = "track.smtp2go.net."; }
    ];
    relay = {
      host = "mail-au.smtp2go.com";
      port = 465;
      username = "stalwart.tecosaur.net";
      credential-file = ../../secrets/credentials/smtp2go.age;
    };
  };
}
