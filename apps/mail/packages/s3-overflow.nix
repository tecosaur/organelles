{ lib
, buildGoModule
, fetchFromGitea
}:

buildGoModule {
  pname = "s3-overflow";
  version = "0.1.0-unstable-2026-10-29";

  src = fetchFromGitea {
    domain = "code.tecosaur.net";
    owner = "tec";
    repo = "s3-overflow";
    rev = "cfb51df3e72ae4d70cee826e15be1864b13f10f7";
    hash = "sha256-kMeda9wi79caseiGvOZf++SaqGYDKik/I+Lxk+FmQ9o=";
  };

  vendorHash = "sha256-TTrPvYYFWQx3elDcY7N0IbvQlRGQ1Q40R+a/IccL+B4=";

  subPackages = [ "cmd/s3-overflow" ];

  checkPhase = ''
    runHook preCheck
    go test ./...
    runHook postCheck
  '';

  meta = {
    description = "S3 gateway that spills Stalwart's blobs to an overflow store while the primary is down";
    homepage = "https://code.tecosaur.net/tec/s3-overflow";
    mainProgram = "s3-overflow";
    platforms = lib.platforms.linux;
  };
}
