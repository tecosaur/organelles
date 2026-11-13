{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "gatus-aggregator";
  version = "0.1.0-unstable-2026-11-13";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "gatus-aggregator";
    rev = "42e59c6b622fe60240e83088957fb9dc73a0b73c";
    hash = "sha256-IP6jBnQBDGgTyU4BwNUg/Hb0uX6zxGklsf/QbnR1xPs=";
  };

  # the standard library alone
  vendorHash = null;

  subPackages = [ "cmd/gatus-aggregator" ];

  checkPhase = ''
    runHook preCheck
    go test ./...
    runHook postCheck
  '';

  meta = {
    description = "Feeds a Gatus status page from a fleet's own reports";
    homepage = "https://code.tecosaur.net/tec/gatus-aggregator";
    mainProgram = "gatus-aggregator";
    platforms = lib.platforms.linux;
  };
}
