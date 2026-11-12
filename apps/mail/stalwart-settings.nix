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
  # Stalwart store objects (InMemoryStore, BlobStore, SearchStore variants), and the
  # Coordinator, Disabled for a lone node
  in-memory-store,
  coordinator,
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
  # This host's mesh address, which the listeners only Caddy dials bind
  mesh-address,
  # Null, or { host; port; username; secret-file; } to send everything through
  relay,
  # The listener apps submit mail on, unauthenticated: only Caddy may reach it
  submission-port,
  # The addresses apps may send as from it, in the envelope and the From header alike
  app-senders,
  # Where mail to an app's noreply@<subdomain> is pointed
  contact,
  # The inbound MTA-STS policy: { mode; max-age-seconds; mx; }
  mta-sts,
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
  rewrite = [
    { condition = "is_local_domain(rcpt_domain)"; value = "false"; }
    # noreply@{app}.{domain} to the noreply account, the address kept as ORCPT
    {
      condition = "email_part(rcpt, 'local') == 'noreply' && split_once(rcpt_domain, '.')[1] == ${quote domain}";
      value = "'noreply+' + split_once(rcpt_domain, '.')[0] + ${quote "@${domain}"}";
    }
  ] ++ map (d: {
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
  from-apps = "local_port == ${toString submission-port}";
  app-sender = if app-senders == [ ] then "false"
    else concatStringsSep " || " (map (address: "sender == ${quote address}") app-senders);
  # The envelope alone would let an app's mail, signed for the site, claim to be from anyone;
  # every From address must be its sender, which isSenderAllowed holds to the app's own
  app-from-script = "app-from";
  app-from-sieve = ''
    require ["envelope", "variables", "relational", "reject"];
    if envelope :all :matches "from" "*" { set "sender" "''${1}"; }
    if anyof (not exists "from", address :all :value "ne" "from" "''${sender}") {
      reject "550 5.7.1 An app's mail must be from its own sender address";
    }
  '';
  # A reply to an app's mail is answered weekly per sender and dropped; anything else is refused
  noreply-script = "noreply";
  noreply-interval-seconds = 604800;
  noreply-sieve = ''
    require ["envelope", "envelope-dsn", "variables", "enotify", "reject", "vnd.stalwart.expressions"];
    # The envelope test reads several recipients as one string, so lists go through expressions
    if eval "contains(envelope.to, 'noreply@${domain}')" {
      set "address" "noreply@${domain}";
      set "alone" "no";
      if eval "count(envelope.to) == 1" {
        set "alone" "yes";
        if envelope :matches "orcpt" ["noreply+*@${domain}", "rfc822;noreply+*@${domain}"] {
          set "address" "noreply@''${1}.${domain}";
        }
      }
      if allof (string :is "''${alone}" "yes",
                anyof (exists "in-reply-to", exists "references"),
                string :is "''${env.dmarc.result}" "pass",
                not envelope :is "from" "",
                anyof (not exists "auto-submitted", header :is "auto-submitted" "no"),
                not exists ["list-id", "list-unsubscribe"],
                not header :is "precedence" ["bulk", "list", "junk"]) {
        if not eval "key_exists(''', 'noreply-answered:' + envelope.from)" {
          eval "key_set(''', 'noreply-answered:' + envelope.from, '1', ${toString noreply-interval-seconds})";
          set "subject" "";
          if header :matches "subject" "*" { set "subject" "''${1}"; }
          set "id" "";
          if header :matches "message-id" "*" { set "id" "''${1}"; }
          set :encodeurl "to" "''${envelope.from}";
          set :encodeurl "id" "''${id}";
          set :encodeurl "body" "''${address} only sends notifications, and nobody reads what is sent to it, so your message was not delivered. To reach a person, write to ${contact}.

    This is an automated reply, which you will not receive again for a week.";
          notify :message "Not delivered: ''${subject}" "mailto:''${to}?In-Reply-To=''${id}&body=''${body}";
        }
        discard;
      } else {
        reject "550 5.7.1 ''${address} does not receive mail; write to ${contact} instead";
      }
    }
  '';
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
    (update "Coordinator" coordinator)
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
    (update "MtaSts" {
      inherit (mta-sts) mode;
      maxAge = mta-sts.max-age-seconds * 1000;
      mxHosts = set mta-sts.mx;
    })
    (set-objects "reconcile" "NetworkListener" [ "name" ] (lib.mapAttrs (name: port: listener-kinds.${name} // {
      inherit name;
      bind = set [ "[::]:${toString port}" ];
    }) public-ports // {
      # No TLS, not even offered: a client would check Stalwart's certificate against loopback
      submission-mesh = {
        name = "submission-mesh";
        protocol = "smtp";
        bind = set [ "[${mesh-address}]:${toString submission-port}" ];
        useTls = false;
      };
      # Caddy reaches it over the mesh, and terminates TLS; the provisioner and Bulwark on loopback
      http = {
        name = "http";
        protocol = "http";
        bind = set [ "[${mesh-address}]:${toString http-port}" "127.0.0.1:${toString http-port}" ];
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
      (lib.listToAttrs (map (a: lib.nameValuePair "account-${a.login}" (account-of a)) accounts) // {
        account-noreply = {
          "@type" = "User";
          name = "noreply";
          domainId = domain-ref domain;
          roles."@type" = "User";
        };
      }))
    (upsert "SieveUserScript" [ "name" ] {
      filing = { name = filing-script; contents = filing-sieve; isActive = true; };
    })
    (upsert "SieveSystemScript" [ "name" ] {
      noreply = {
        name = noreply-script;
        description = "Drops a person's reply to an app's noreply address, answering it once a week per sender, and rejects other mail there";
        contents = noreply-sieve;
        isActive = true;
      };
      app-from = {
        name = app-from-script;
        description = "Rejects an app's mail unless every From address is its envelope sender";
        contents = app-from-sieve;
        isActive = true;
      };
    })
    (update "SieveSystemInterpreter" {
      defaultFromAddress."else" = quote "noreply@${domain}";
      defaultFromName."else" = quote domain;
    })
    # Each else is Stalwart's default
    (update "MtaStageAuth" {
      mustMatchSender."else" = send-as;
      require = expression [ { condition = from-apps; value = "false"; } ] "local_port != 25";
    })
    (update "MtaStageMail" {
      isSenderAllowed = expression [ { condition = from-apps; value = app-sender; } ]
        "!is_empty(authenticated_as) || !key_exists('spam-block', sender_domain)";
    })
    # Stalwart's default throttles, sparing apps' mail, which all arrives from Caddy
    (upsert "MtaInboundThrottle" [ "description" ] (lib.mapAttrs (_: throttle: throttle // {
      enable = true;
      match."else" = "!(${from-apps})";
    }) {
      sender-ip = {
        description = "Sender IP throttle";
        key = set [ "remoteIp" ];
        rate = { count = 5; period = 1000; };
      };
      sender-recipient = {
        description = "Sender address to recipient throttle";
        key = set [ "senderDomain" "rcpt" ];
        rate = { count = 25; period = 3600000; };
      };
    }))
    (update "MtaStageRcpt" {
      rewrite = expression rewrite "false";
      allowRelaying = expression [ { condition = from-apps; value = "true"; } ] "!is_empty(authenticated_as)";
    })
    (update "MtaStageData" {
      maxMessageSize."else" = toString max-message-bytes;
      script = expression [
        { condition = "local_port == 25"; value = quote noreply-script; }
        { condition = from-apps; value = quote app-from-script; }
      ] "false";
      enableSpamFilter = expression [ { condition = from-apps; value = "false"; } ] "is_empty(authenticated_as)";
      dkimSignDomain = expression (map (name: {
        condition = "(!is_empty(authenticated_as) || ${from-apps}) && (sender_domain == ${quote name} || ends_with(sender_domain, ${quote ".${name}"}))";
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
