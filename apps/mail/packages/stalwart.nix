# Stalwart 1.0.3 built without the enterprise feature: the store's schema is tied to the edition that wrote it, and
# this site's was written AGPL-only. Vendored from nixpkgs' stalwart_1_0 until nixpkgs reaches 1.0.3, then deleted.
{ lib, rustPlatform, fetchFromGitHub, fetchurl, pkg-config, protobuf, bzip2, openssl, zstd, stalwart_1_0 ? null }:

let
  vendored = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "stalwart";
    version = "1.0.3";

    __structuredAttrs = true;

    src = fetchFromGitHub {
      owner = "stalwartlabs";
      repo = "stalwart";
      tag = "v${finalAttrs.version}";
      hash = "sha256-4NUb6Peivb5yG4jZSKUSwYijoF4JTvw4+u2uvN4tGqU=";
    };

    cargoHash = "sha256-QOdPdcCa5HxckfMiNkgnkGMuOlRGIfMMylQs7QUGI5Q=";

    env = {
      OPENSSL_NO_VENDOR = true;
      OPENSSL_DIR = lib.getDev openssl;
      OPENSSL_LIB_DIR = "${lib.getLib openssl}/lib";
      ZSTD_SYS_USE_PKG_CONFIG = true;
    };

    depsBuildBuild = [ pkg-config zstd ];
    nativeBuildInputs = [ protobuf rustPlatform.bindgenHook ];
    buildInputs = [ bzip2 openssl zstd ];

    # Only the stores the site uses: PostgreSQL data, S3 blobs, Redis Sentinel for in-memory state.
    # RocksDB, the default, needs a newer release than nixpkgs has.
    buildNoDefaultFeatures = true;
    buildFeatures = [ "postgres" "s3" "redis" ];
    cargoBuildFlags = [ "-p" "stalwart" ];

    # Upstream's suites need RocksDB and live services, and nixpkgs runs them for its own build
    doCheck = false;

    # The bundle Stalwart would otherwise fetch from GitHub at start
    passthru.webui = fetchurl {
      url = "https://github.com/stalwartlabs/webui/releases/download/v2.0.5/webui.zip";
      hash = "sha256-FSpj80uy9HDDL+nGj5fjlZlMdhMDNks5KizkGbLwYWI=";
    };

    meta = {
      description = "Secure, modern, all-in-one mail and collaboration server";
      homepage = "https://github.com/stalwartlabs/stalwart";
      changelog = "https://github.com/stalwartlabs/stalwart/blob/${finalAttrs.src.tag}/CHANGELOG.md";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
      mainProgram = "stalwart";
    };
  });
in
if stalwart_1_0 != null && lib.versionAtLeast stalwart_1_0.version vendored.version
then lib.warn "nixpkgs' stalwart_1_0 has caught up: delete apps/mail/packages/stalwart.nix and use pkgs.stalwart_1_0 (its webui passthru may differ)." vendored
else vendored
