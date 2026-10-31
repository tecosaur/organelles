{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "gatus-aggregator";
  version = "0.1.0-unstable-2026-10-31";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "gatus-aggregator";
    rev = "d168bf37a0784f4b1f156e0f685f5c8d15f96d0c";
    hash = "sha256-vRKpCP1ap7lvnTkqB/mBSzNKxWe/+Td1DqdeQoHIz+E=";
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
