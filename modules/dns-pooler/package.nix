{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "dns-pooler";
  version = "0.1.0-unstable-2026-11-13";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "dns-pooler";
    rev = "2e299a3884ff15aab2aa8b6b677b8cc927a64e4f";
    hash = "sha256-PWfaeCW4Slrfd55KGZTn+LvD9vuFG4BSr9gdlcOHNRU=";
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
