{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "dns-pooler";
  version = "0.1.0-unstable-2026-10-28";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "dns-pooler";
    rev = "4c56eb5b91e6dd7e0dd1f7269745aeca152a7b82";
    hash = "sha256-9Io0J7wQIkZOL7k5qm+UTe8K/ZuMx6ZG3gfJan5tRYo=";
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
