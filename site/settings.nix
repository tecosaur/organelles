{
  # The site's own values; per-app ones are in each app's site.nix
  config.site = {
    domain = "tecosaur.net";
    # mail's records are apps/mail/stalwart.nix's
    dns.records = [
      { name = "ssh"; type = "CNAME"; value = "golgi.hosts.tecosaur.net."; }
    ];
    server.admin = {
      hashedPassword = "$6$ET8BLqODvw77VOmI$oun2gILUqBr/3WonH2FO1L.myMIM80KeyO5W1GrYhJTo./jk7XcG8B3vEEcbpfx3R9h.sR0VV187/MgnsnouB1";
      authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZZqcJOLdN+QFHKyW8ST2zz750+8TdvO9IT5geXpQVt tec@tranquillity" ];
    };
    email = {
      server = "smtp.fastmail.com";
      username = "tec@tecosaur.net";
    };
    accent = {
      primary = "#239a58";
      secondary = "#67bc85";
    };
  };
}
