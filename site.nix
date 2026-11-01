# The site's settings: everything particular to this site, which the apps and modules
# leave generic. flake.nix gives them to every machine, and site/manifest.nix reads them
# for the secrets' rules.
{
  # each built by flake.nix's machines
  hosts = [ "centrosome" "golgi" "nucleus" ];
  domain = "tecosaur.net";
  ha.preference = [ "nucleus" "golgi" ];
  meilisearch.host = "nucleus";
  # mail's records are apps/mail/stalwart.nix's
  dns.records = [
    { name = "ssh"; type = "CNAME"; value = "golgi.hosts.tecosaur.net."; }
  ];
  server.admin = {
    hashedPassword = "$6$ET8BLqODvw77VOmI$oun2gILUqBr/3WonH2FO1L.myMIM80KeyO5W1GrYhJTo./jk7XcG8B3vEEcbpfx3R9h.sR0VV187/MgnsnouB1";
    authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZZqcJOLdN+QFHKyW8ST2zz750+8TdvO9IT5geXpQVt tec@tranquillity" ];
  };
  mail = {
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
    relay = {
      host = "mail-au.smtp2go.com";
      port = 465;
      username = "stalwart.tecosaur.net";
      spf = "include:spf.smtp2go.com";
      records = [
        { name = "mailbounces"; type = "CNAME"; value = "return.smtp2go.net."; }
        { name = "s766060._domainkey"; type = "CNAME"; value = "dkim.smtp2go.net."; }
        { name = "mailtrack"; type = "CNAME"; value = "track.smtp2go.net."; }
      ];
    };
  };
  accent = {
    primary = "#239a58";
    secondary = "#67bc85";
  };
  apps = {
    beszel.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL6RP5omIbCzQsC/NizUg56JgpgMdl0/VXmCAE0VyJlq";
    dawarich.groups = { primary = "timeline"; extra = [ "family" ]; };
    mealie.subdomain = "food";
    memos.groups.extra = [ "family" ];
    microbin = {
      title = "μPaste";
      subdomain = "pastes";
      short-subdomain = "p";
      groups.primary = "paste";
    };
    forgejo = {
      groups.primary = "forge";
      site-name = "Code by TEC";
      site-description = "The personal Forgejo instance of TEC";
      qa-captcha = {
        enabled = true;
        questions = [
          "What is my first name?"
          "What is the thing I use as my avatar?"
          "What is the mononym I often go by online?"
          "What community do you know me from?"
        ];
        answers = [
          "timothy"
          "tec"
          "tree"
          "tecosaur"
          "julia"
          "julialang"
          "emacs"
          "org"
          "doom"
        ];
      };
      default-user-redirect = "tec";
      served-repositories = [
        {
          repo = "tec/this-month-in-org";
          rev = "html";
          subdomain = "blog";
          path = "tmio";
        }
      ];
    };
    home-assistant.subdomain = "doonan";
    paperless.groups.extra = [ "family" ];
    rustical.groups = { primary = "caldav"; extra = [ "family" ]; };
    sftpgo.groups.extra = [ "family" ];
    storyteller.groups.extra = [ "family" ];
    tandoor.groups.extra = [ "family" ];
    immich = {
      groups.extra = [ "family" ];
      mail.reply-to = "contact.immich@tecosaur.net";
    };
    jellyfin.groups.extra = [ "family" ];
    koito = {
      title = "Listens";
      groups.primary = "listens";
    };
    multi-scrobbler = {
      jellyfin-user = "tec";
      listenbrainz-user = "tecosaur";
    };
    warracker.groups.extra = [ "family" ];
  };
}
