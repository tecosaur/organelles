{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "gatus-aggregator";
  version = "0.1.0-unstable-2026-10-28.2";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "gatus-aggregator";
    rev = "72989fd7427fdc32a349525f6c0994e37a67a86b";
    hash = "sha256-SwrAGJydyXV06NTiChsjq92IjiALA5YkbfL0EAgPvmg=";
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
