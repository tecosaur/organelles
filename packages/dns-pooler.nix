{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "dns-pooler";
  version = "0.1.0-unstable-2026-10-31";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "dns-pooler";
    rev = "5bc6892af8838c9aa0485560349f1549b6aab592";
    hash = "sha256-sSGWmRk/LAQSeM0tDKrlOArAchPPojfkpCVR72GCXhI=";
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
