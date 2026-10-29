{ lib }:

# Who has mail where, from site.mail.domains and site.mail.admins, as plain data for Stalwart's
# settings and provisioning. Only users listed in a domain's `users` are known here: a group
# member's account appears at their first sign-in, so which account a sign-in gets is also
# given as a rule for Authelia to evaluate then.

{ domains, admins }:
let
  inherit (lib) attrNames concatMap concatStringsSep elem filter head unique;
  names = attrNames domains;
  expand = user: domain: lib.replaceStrings [ "{user}" "{domain}" ] [ user domain ];
  domain-of = address: lib.last (lib.splitString "@" address);
  local-of = address: head (lib.splitString "@" address);
  logins = unique (concatMap (d: domains.${d}.users) names);
  domains-listing = user: filter (d: elem user domains.${d}.users) names;
  # The first is the canonical address, which names the account
  addresses-of = user: unique (concatMap (d: map (expand user d) domains.${d}.addresses) (domains-listing user));
  canonical = user: head (addresses-of user);
  domains-with = option: filter (d: domains.${d}.${option} != null) names;
  domains-where = role: user: filter (d: domains.${d}.${role} == user) (domains-with role);
  filing-domains = domains-with "filing";
  group-domains = domains-with "group";
  claims = concatMap (user: map (address: { inherit address user; }) (addresses-of user)) logins;
  errors =
    map (d: "mail domain ${d} is not a lowercase domain name; rename it in site.mail.domains")
      (filter (d: builtins.match "[a-z0-9-]+(\\.[a-z0-9-]+)+" d == null) names)
    ++ concatMap (d: map (template: "mail domain ${d}'s address template ${template} lacks {user}, so its users would share it; add {user} to it in site.mail.domains.\"${d}\".addresses")
      (filter (template: !lib.hasInfix "{user}" template) domains.${d}.addresses)) names
    ++ map (c: "mail address ${c.address} of ${c.user} is in no mail domain; add ${domain-of c.address} to site.mail.domains")
      (filter (c: !domains ? ${domain-of c.address}) claims)
    ++ lib.mapAttrsToList (address: owners: "mail address ${address} is claimed by ${concatStringsSep " and " owners}; change a template in site.mail.domains so their addresses differ")
      (lib.filterAttrs (_: owners: lib.length owners > 1) (lib.mapAttrs (_: map (c: c.user)) (lib.groupBy (c: c.address) (unique claims))))
    ++ concatMap (role: map (d: "mail domain ${d}'s ${role} is ${domains.${d}.${role}}, who is in no domain's users; add them to a mail domain's users in site.mail.domains")
      (filter (d: !elem domains.${d}.${role} logins) (domains-with role))) [ "catch-all" "catch-subdomains" ]
    ++ map (admin: "mail admin ${admin} is in no domain's users, and no domain has a group; add them to a mail domain's users in site.mail.domains")
      (filter (admin: !elem admin logins && group-domains == [ ]) admins);
  account = user: {
    login = user;
    addresses = addresses-of user;
    canonical = canonical user;
    admin = elem user admins;
    # What it receives beyond its own addresses: whole domains (its catch-alls, and the
    # {user}.{domain} of each address it can file at), and anything beneath others
    catches = {
      domains = domains-where "catch-all" user
        ++ map (a: "${local-of a}.${domain-of a}") (filter (a: elem (domain-of a) filing-domains) (addresses-of user));
      subdomains-of = domains-where "catch-subdomains" user;
    };
  };
  hosted = name: let d = domains.${name}; in {
    inherit name;
    # A subdomain of another mail domain signs with that domain's key
    signs = !lib.any (other: lib.hasSuffix ".${other}" name) names;
    catch-all = lib.mapNullable canonical d.catch-all;
    catch-subdomains = lib.mapNullable canonical d.catch-subdomains;
    files = d.filing != null;
  };
  # The sign-in rule, in CEL: a listed user's canonical address, else a group member's address
  # in their group's domain, else "", which omits the claim
  cel-string = s: "\"${s}\"";
  cel-address = d: concatStringsSep " + " (filter (part: part != cel-string "") (lib.intersperse "username"
    (map cel-string (lib.splitString "{user}" (expand "{user}" d (head domains.${d}.addresses))))));
  listed-addresses = unique (concatMap addresses-of logins);
  # A group member's login must be one a listed user could have, and their address no listed user's
  member-condition = d: concatStringsSep " && " ([
    "${cel-string domains.${d}.group} in groups"
    "username.matches(${cel-string "^[a-z0-9][a-z0-9_-]*$"})"
  ] ++ lib.optional (listed-addresses != [ ])
    "!(${cel-address d} in [${concatStringsSep ", " (map cel-string listed-addresses)}])");
in lib.throwIf (errors != [ ]) (concatStringsSep "; " errors) {
  accounts = map account logins;
  domains = map hosted names;
  # Which account a sign-in gets, and who may sign in, for Authelia
  sign-in = {
    account = lib.foldr (branch: otherwise: "${branch.condition} ? ${branch.value} : ${otherwise}") (cel-string "")
      (map (user: { condition = "username == ${cel-string user}"; value = cel-string (canonical user); }) logins
        ++ map (d: { condition = member-condition d; value = cel-address d; }) group-domains);
    subjects = map (user: "user:${user}") logins ++ unique (map (d: "group:${domains.${d}.group}") group-domains);
  };
  # Every admin's account: a listed admin's, and for the others each group domain's name for them
  admin-accounts = map canonical (filter (user: elem user admins) logins)
    ++ concatMap (admin: map (d: expand admin d (head domains.${d}.addresses)) group-domains)
      (filter (admin: !elem admin logins) admins);
}
