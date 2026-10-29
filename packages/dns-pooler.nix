{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "dns-pooler";
  version = "0.1.0-unstable-2026-10-29";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "dns-pooler";
    rev = "e178d7edbe67d7ec4e521921fa9680e8b9ec3e53";
    hash = "sha256-uxWlOpXVw+mrUeJJkp9jot4eNGv14iE+NuGM+nV91Dg=";
  };

  vendorHash = "sha256-D8rsQO3nO56DbNKTGnV8rA7trBFKRPqCptB4S+uUQ04=";

  subPackages = [ "cmd/dns-pooler" ];

  # The whole suite, simulation included, rather than only what
  # subPackages builds.
  checkPhase = ''
    runHook preCheck
    go test ./...
    runHook postCheck
  '';

  meta = {
    description = "Keeps a DNS zone's pools matching the hosts able to serve them";
    homepage = "https://code.tecosaur.net/tec/dns-pooler";
    mainProgram = "dns-pooler";
    platforms = lib.platforms.linux;
  };
}
