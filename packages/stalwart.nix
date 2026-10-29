# Stalwart's release build, which carries every feature the site uses; built from source it takes
# hours and a newer RocksDB than nixpkgs has
{ lib, stdenv, fetchurl, autoPatchelfHook }:

stdenv.mkDerivation (finalAttrs: {
  pname = "stalwart";
  version = "1.0.3";

  src = fetchurl {
    url = "https://github.com/stalwartlabs/stalwart/releases/download/v${finalAttrs.version}/stalwart-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-iuSB/0EM0J3VPX9J9SjcrTXZC0sv+wxJya4jqvQ8SDE=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 stalwart $out/bin/stalwart
    runHook postInstall
  '';

  # The bundle Stalwart would otherwise fetch from GitHub at start
  passthru.webui = fetchurl {
    url = "https://github.com/stalwartlabs/webui/releases/download/v2.0.5/webui.zip";
    hash = "sha256-FSpj80uy9HDDL+nGj5fjlZlMdhMDNks5KizkGbLwYWI=";
  };

  meta = {
    description = "Secure, modern, all-in-one mail and collaboration server";
    homepage = "https://github.com/stalwartlabs/stalwart";
    changelog = "https://github.com/stalwartlabs/stalwart/blob/v${finalAttrs.version}/CHANGELOG.md";
    # The release build includes the enterprise code, inert without a licence
    license = [ lib.licenses.agpl3Only lib.licenses.stalwart ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "stalwart";
  };
})
