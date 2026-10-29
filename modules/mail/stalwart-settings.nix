{ lib }:

# Stalwart's settings as a `stalwart-cli apply` plan (NDJSON), from addressing.nix's model and
# the deployment. Secrets are file paths, so the settings may sit in the store; upserts on
# natural keys make applying them idempotent.

addressing:
{
  domain,
  hostname,
  # Listener name (smtp, submissions, submission, imaps, sieve) -> public port
  public-ports,
  # Stalwart store objects (InMemoryStore, BlobStore, SearchStore variants)
  in-memory-store,
  blob-store,
  search-store,
  # site.mail.oidc, to sign in through Authelia
  oidc,
  # { contact; bunny-key; }, to obtain the hostname's certificate by DNS-01 through Bunny
  acme,
  # Sending domain -> path of its PEM DKIM key
  dkim-keys,
  dkim-selector,
  http-port,
  max-message-bytes,
  # file:// URL of the WebUI bundle, and the OAuth client it signs in as
  web-ui,
  # The global Sieve script that files mail, which each account's stub includes
  filing-script,
  # Directory of the log file the admin UI's log viewer reads
  log-dir,
  # Null, or { host; port; username; secret-file; } to send everything through
  relay ? null,
}:
let
  inherit (lib) concatStringsSep filter optional optionals;
  inherit (addressing) accounts;
  hosted = addressing.domains;
  quote = s: "'${s}'";
  file = file-path: { "@type" = "File"; filePath = file-path; };
  # Stalwart encodes lists as objects keyed by index, and sets as objects of `true`
  list = items: lib.listToAttrs (lib.imap0 (i: lib.nameValuePair (toString i)) items);
  set = items: lib.genAttrs items (_: true);
  expression = branches: otherwise: {
    match = list (map (branch: { "if" = branch.condition; "then" = branch.value; }) branches);
    "else" = otherwise;
  };
  domain-ref = name: "#domain-${name}";
  split-address = address: let parts = lib.splitString "@" address; in {
    local = lib.head parts;
    domain = lib.last parts;
  };
  by-specificity = lib.sort (a: b: lib.stringLength a > lib.stringLength b);
  filing = map (d: d.name) (filter (d: d.files) hosted);
  # Most specific first, so a nested domain's catcher wins
  subdomain-catchers = lib.sort (a: b: lib.stringLength a.name > lib.stringLength b.name)
    (filter (d: d.catch-subdomains != null) hosted);
  # Most specific first, so a sending domain beneath another signs with its own key
  dkim-domains = by-specificity (map (d: d.name) (filter (d: d.signs) hosted));
  # Routing: a result without "@" leaves the recipient alone, and mail domains keep their own addresses
  label = "split_once(rcpt_domain, '.')[0]";
  rewrite = optionals (filing ++ subdomain-catchers != [ ]) [ { condition = "is_local_domain(rcpt_domain)"; value = "false"; } ]
    ++ map (d: {
      # {location}@{user}.{domain} files for whoever has {user}@{domain}
      condition = "split_once(rcpt_domain, '.')[1] == ${quote d} && is_local_address(${label} + ${quote "@${d}"})";
      value = "${label} + '+' + email_part(rcpt, 'local') + ${quote "@${d}"}";
    }) filing
    ++ map (d: {
      condition = "ends_with(rcpt_domain, ${quote ".${d.name}"})";
      value = quote d.catch-subdomains;
    }) subdomain-catchers;
  # Sending: an account may send as whatever it receives. mustMatchSender: true holds the
  # envelope sender to the account's own addresses.
  catch-clauses = account:
    map (d: "sender_domain == ${quote d}") account.catches.domains
    ++ map (d: "ends_with(sender_domain, ${quote ".${d}"})") account.catches.subdomains-of;
  sender-label = "split_once(sender_domain, '.')";
  # Any account's own filing domain, whose label and parent spell the account
  own-filing-clause = "(${concatStringsSep " || " (map (d: "${sender-label}[1] == ${quote d}") filing)})"
    + " && ${sender-label}[0] + '@' + ${sender-label}[1] == authenticated_as";
  send-as =
    let clauses = optional (filing != [ ]) "(${own-filing-clause})"
      ++ map (account: "(authenticated_as == ${quote account.canonical} && (${concatStringsSep " || " (catch-clauses account)}))")
        (filter (account: catch-clauses account != [ ]) accounts);
    in if clauses == [ ] then "true" else "!(${concatStringsSep " || " clauses})";
  # Delivery to {user}+{location}@{domain} keeps that address only as ORCPT. What follows
  # its first +, less any further +tag, is split on dots (:detail would take the last +).
  filing-sieve = ''
    require ["envelope", "envelope-dsn", "variables", "fileinto", "mailbox"];
    if envelope :localpart :matches "orcpt" "*+*" {
      set "local" "''${2}";
      if string :matches "''${local}" "*+*" { set "local" "''${1}"; }
      if string :matches "''${local}" "*.*.*" { set "a" "''${1}"; set "b" "''${2}"; set "c" "''${3}"; }
      elsif string :matches "''${local}" "*.*" { set "a" "''${1}"; set "b" "''${2}"; }
      else { set "a" "''${local}"; }
      if allof (not string :is "''${c}" "", mailboxexists "''${a}/''${b}/''${c}") { fileinto "''${a}/''${b}/''${c}"; }
      elsif allof (not string :is "''${b}" "", mailboxexists "''${a}/''${b}") { fileinto "''${a}/''${b}"; }
      elsif mailboxexists "''${a}" { fileinto "''${a}"; }
    }
  '';
  account-of = account:
    let primary = split-address account.canonical;
    in {
      "@type" = "User";
      name = primary.local;
      domainId = domain-ref primary.domain;
      roles."@type" = if account.admin then "Admin" else "User";
      aliases = list (map (address: let a = split-address address; in {
        name = a.local;
        domainId = domain-ref a.domain;
        enable = true;
      }) (lib.tail account.addresses));
    };
  listener-kinds = {
    smtp.protocol = "smtp";
    submissions = { protocol = "smtp"; implicitTls = true; };
    submission.protocol = "smtp";
    imaps = { protocol = "imap"; implicitTls = true; };
    sieve.protocol = "manageSieve";
  };
  # reconcile also deletes what is not named here
  set-objects = kind: object: match-on: values: {
    "@type" = kind;
    inherit object;
    matchOn = match-on;
    value = values;
  };
  upsert = set-objects "upsert";
  update = object: value: { "@type" = "update"; inherit object value; };
  operations = [
    # The in-memory store first: the coordinator reuses its connection
    (update "InMemoryStore" in-memory-store)
    (update "Coordinator" { "@type" = "Default"; })
    (update "BlobStore" blob-store)
    (update "SearchStore" search-store)
    # Stalwart validates DNSSEC itself, and the system's stub resolver withholds the signatures it
    # needs, which disables DANE: so its mail lookups go to Cloudflare over TLS
    (update "DnsResolver" { "@type" = "Cloudflare"; useTls = true; })
    (upsert "Directory" [ "description" ] {
      directory = {
        "@type" = "Oidc";
        description = "Authelia";
        issuerUrl = oidc.issuer;
        acceptedAudiences = set [ oidc.audience ];
        # Only our own clients get the audience, and Bulwark's account settings need more than
        # the interoperable JMAP scopes
        unscopedTokens = "full";
        claimUsername = oidc.account-claim;
        # The account's display name; Stalwart asks userinfo for any claim the token lacks
        claimName = "name";
        # Only so the WebUI never requests email, which the mail clients are not granted
        usernameDomain = domain;
      };
    })
    (update "Authentication" { directoryId = "#directory"; })
    # The ACME operations below manage the site domain's certificate
    (upsert "Domain" [ "name" ] (lib.listToAttrs (map (d: lib.nameValuePair "domain-${d.name}" ({
      inherit (d) name;
      catchAllAddress = d.catch-all;
      subAddressing."@type" = "Enabled";
      dkimManagement."@type" = "Manual";
    } // lib.optionalAttrs (d.name != domain) {
      dnsManagement."@type" = "Manual";
      certificateManagement."@type" = "Manual";
    })) hosted)))
  ] ++ optional (dkim-domains != [ ])
    (upsert "DkimSignature" [ "domainId" "selector" ] (lib.listToAttrs (map (name: lib.nameValuePair "dkim-${name}" {
      "@type" = "Dkim1RsaSha256";
      domainId = domain-ref name;
      selector = dkim-selector;
      privateKey = file dkim-keys.${name};
    }) dkim-domains)))
  ++ [
    # Without a default, Stalwart serves the hostname's certificate, self-signed until issued
    (update "SystemSettings" {
      defaultHostname = hostname;
      defaultDomainId = domain-ref domain;
    })
    (set-objects "reconcile" "NetworkListener" [ "name" ] (lib.mapAttrs (name: port: listener-kinds.${name} // {
      inherit name;
      bind = set [ "[::]:${toString port}" ];
    }) public-ports // {
      # Only Caddy reaches it, this host's or another's over the mesh, and it terminates TLS
      http = {
        name = "http";
        protocol = "http";
        bind = set [ "[::]:${toString http-port}" ];
        useTls = false;
      };
    }))
    # STALWART_ROLE picks one per node; tasks that must run once go on the scheduler alone
    (upsert "ClusterRole" [ "name" ] {
      scheduler = { name = "scheduler"; tasks."@type" = "EnableAll"; };
      worker = {
        name = "worker";
        tasks = { "@type" = "DisableSome"; taskTypes = set [ "taskScheduler" "spamClassifierTraining" ]; };
      };
    })
    (upsert "Account" [ "name" "domainId" ]
      (lib.listToAttrs (map (a: lib.nameValuePair "account-${a.login}" (account-of a)) accounts)))
    (upsert "SieveUserScript" [ "name" ] {
      filing = { name = filing-script; contents = filing-sieve; isActive = true; };
    })
    (update "MtaStageAuth" { mustMatchSender."else" = send-as; })
    (update "MtaStageRcpt" { rewrite = expression rewrite "false"; })
    (update "MtaStageData" {
      maxMessageSize."else" = toString max-message-bytes;
      dkimSignDomain = expression (map (name: {
        condition = "!is_empty(authenticated_as) && (sender_domain == ${quote name} || ends_with(sender_domain, ${quote ".${name}"}))";
        value = quote name;
      }) dkim-domains) "false";
    })
    # Outside recovery mode Stalwart logs only through these. Matched by value, so every field is
    # given; a tracer not named here is removed.
    (set-objects "reconcile" "Tracer" "*" (lib.mapAttrs (_: tracer: tracer // {
      enable = true;
      level = "info";
      lossy = false;
      eventsPolicy = "exclude";
    }) {
      journal."@type" = "Journal";
      file = {
        "@type" = "Log";
        path = log-dir;
        prefix = "stalwart.log";
        rotate = "daily";
        ansi = true;
        multiline = false;
      };
    }))
    # Caddy's address would otherwise stand for every client, to rate limits and bans
    (update "Http" { clientIpSource = "xForwardedFor"; forwardedHops = 1; })
    # Only local requests come from loopback, and the host's own probes must never be banned
    (upsert "AllowedIp" [ "address" ] (lib.mapAttrs (_: address: {
      inherit address;
      reason = "This host's own probes";
    }) { loopback-ipv4 = "127.0.0.1"; loopback-ipv6 = "::1"; }))
    (upsert "Application" [ "description" ] {
      web-ui = {
        description = "Stalwart Web Interface";
        enable = true;
        resourceUrl = web-ui.bundle;
        urlPrefix = set [ "/admin" "/account" ];
        oauthClientId = web-ui.client-id;
        # Authelia releases the claim Stalwart names accounts by only with its own scope
        oauthScopes = set [ oidc.account-claim ];
      };
    })
  ] ++ optionals (relay != null) [
    (upsert "MtaRoute" [ "name" ] {
      relay = {
        "@type" = "Relay";
        name = "relay";
        inherit (relay) host port;
        protocol = "smtp";
        implicitTls = relay.port == 465;
        authUsername = relay.username;
        authSecret = file relay.secret-file;
      };
    })
    (update "MtaOutboundStrategy" {
      route = expression [ { condition = "is_local_domain(rcpt_domain)"; value = "'local'"; } ] "'relay'";
      # The default retries a TLS failure without validation
      tls."else" = "'default'";
    })
  ] ++ [
    # Last, and applied apart: creating the provider registers an account with Let's Encrypt
    (upsert "AcmeProvider" [ "description" ] {
      acme = {
        description = "Let's Encrypt";
        directory = "https://acme-v02.api.letsencrypt.org/directory";
        challengeType = "Dns01";
        contact = set [ acme.contact ];
      };
    })
    (upsert "DnsServer" [ "description" ] {
      dns = { "@type" = "Bunny"; description = "Bunny"; secret = file acme.bunny-key; };
    })
    (upsert "Domain" [ "name" ] {
      "domain-${domain}" = {
        name = domain;
        # DNS-01 needs automatic DNS management, which must publish at least one type, once. The
        # zone is dns-pooler's, which removes it again: TLS-RPT's lone TXT is the most harmless.
        dnsManagement = { "@type" = "Automatic"; dnsServerId = "#dns"; publishRecords = set [ "tlsRpt" ]; };
        certificateManagement = { "@type" = "Automatic"; acmeProviderId = "#acme"; subjectAlternativeNames = set [ hostname ]; };
      };
    })
  ];
in
lib.concatMapStrings (op: builtins.toJSON op + "\n") operations
