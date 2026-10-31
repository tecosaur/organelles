{
  lib,
  stdenv,
  fetchFromGitLab,
  fetchFromGitHub,
  fetchurl,
  yarn-berry_4,
  nodejs_26,
  srcOnly,
  removeReferencesTo,
  makeWrapper,
  ffmpeg,
  sqlite,
  gcc,
  python3,
  git,
  unzip,
  buildGoModule,
  whisper-cpp,
  whisper ? whisper-cpp,
  vulkan-loader,
  curl,
  libxml2_13,
  zlib,
  fraunces,
  ibm-plex
}:

let
  nodeSources = srcOnly nodejs_26;
  # Upstream's lockfile is written by yarn 4.18, whose builtin TypeScript
  # compat patch knows the TypeScript 7 package layout; nixpkgs' 4.14 does not
  # and fails the fetch step on lib/_tsc.js.
  yarn-berry = yarn-berry_4.overrideAttrs (old: {
    version = "4.18.0";
    src = fetchFromGitHub {
      owner = "yarnpkg";
      repo = "berry";
      tag = "@yarnpkg/cli/4.18.0";
      hash = "sha256-pO89wh17cW9/RGKjo70yiefr+9nlJAQs4ZEdUnzdgQM=";
    };
  });

  readium-cli = buildGoModule rec {
    pname = "readium-cli";
    version = "0.9.1";

    src = fetchFromGitHub {
      owner = "readium";
      repo = "cli";
      rev = "v${version}";
      hash = "sha256-D7Qpf+6qMdXWQ35zdIBZTVpT6zJEK7TVpjpLDPg+/n0=";
    };

    vendorHash = "sha256-Jph5NafR7PSrH2ub+85Cd/QxHPi6UyvyDJdlfsJrQNw=";

    subPackages = [ "cmd" ];

    postInstall = ''
      mv $out/bin/cmd $out/bin/readium
    '';

    meta = {
      description = "Readium CLI for EPUB processing and streaming";
      homepage = "https://github.com/readium/cli";
      license = lib.licenses.bsd3;
      mainProgram = "readium";
    };
  };

  epubcheckVersion = "5.3.0";

  epubcheckZip = fetchurl {
    url = "https://github.com/w3c/epubcheck/releases/download/v${epubcheckVersion}/epubcheck-${epubcheckVersion}.zip";
    hash = "sha256-bAfmhYSy4s4vif4G4SRt/q0+s2tGs0Dn2TUk8p3P9sU=";
  };

  ibmPlex = ibm-plex.override {
    families = [
      "sans-variable"
      "serif-variable"
    ];
  };

  yarnPatch = ''
    # Add dependenciesMeta to package.json and mirror it into yarn.lock.
    ${nodejs_26}/bin/node <<'JS'
    const fs = require("fs");

    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    pkg.dependenciesMeta = {
      ...pkg.dependenciesMeta,
      electron: { built: false },
      sqlite3: { built: false },
      "better-sqlite3": { built: false },
      "onnxruntime-node": { built: false },
    };
    fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");

    const lockPath = "yarn.lock";
    let lock = fs.readFileSync(lockPath, "utf8");

    const resolution = '  resolution: "' + pkg.name + '@workspace:."';
    const rootEntry = lock.indexOf(resolution);

    if (rootEntry === -1) {
      throw new Error("Could not find root workspace entry: " + resolution);
    }

    const nextEntry = lock.indexOf('\n"', rootEntry + resolution.length);
    const blockEnd = nextEntry === -1 ? lock.length : nextEntry + 1;
    const rootBlock = lock.slice(rootEntry, blockEnd);

    const languageName = lock.indexOf("  languageName:", rootEntry);

    if (languageName === -1 || languageName >= blockEnd) {
      throw new Error("Could not find insertion point in root workspace entry");
    }

    if (!rootBlock.includes("  dependenciesMeta:\n")) {
      const metaText =
        "  dependenciesMeta:\n" +
        "    electron:\n" +
        "      built: false\n" +
        "    onnxruntime-node:\n" +
        "      built: false\n" +
        "    better-sqlite3:\n" +
        "      built: false\n" +
        "    sqlite3:\n" +
        "      built: false\n";

      lock = lock.slice(0, languageName) + metaText + lock.slice(languageName);
      fs.writeFileSync(lockPath, lock);
    }
    JS
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "storyteller";
  version = "3.0.0-beta.58";

  src = fetchFromGitLab {
    owner = "storyteller-platform";
    repo = "storyteller";
    rev = "web-v${finalAttrs.version}";
    hash = "sha256-J8EBDTQOpzUSyQVsVnbiDyUbKB71CDNkZlNC3ZFsOT8=";
  };

  nativeBuildInputs = [
    nodejs_26
    yarn-berry
    yarn-berry.yarnBerryConfigHook
    makeWrapper
    gcc
    python3
    git
    unzip
  ];

  missingHashes = ./storyteller-missing-yarn-hashes.json; # From `nix run 'nixpkgs#yarn-berry_4.yarn-berry-fetcher' missing-hashes yarn.lock`
  offlineCache = yarn-berry.fetchYarnBerryDeps {
    inherit (finalAttrs) src missingHashes;
    postPatch = yarnPatch;
    hash = "sha256-T9f84io5b6qwJ/moxTugyKfYX3iwqDvU+s18VeRqwT8=";
  };

  passthru = {
    inherit (finalAttrs) offlineCache;
  };

  buildInputs = [
    sqlite.dev
  ];

  postPatch = yarnPatch;

  # After the yarn configure, build native modules that need special handling.
  preBuild = ''
    # EPUBCheck is stored upstream through Git LFS. Fetch and extract it
    # explicitly for the Nix build.
    mkdir -p libraries/epub/vendors
    unzip -q ${epubcheckZip} -d libraries/epub/vendors

    if [[ ! -f libraries/epub/vendors/epubcheck-${epubcheckVersion}/epubcheck.jar ]]; then
      echo "ERROR: epubcheck-${epubcheckVersion}/epubcheck.jar missing"
      find libraries/epub/vendors -maxdepth 3 -print
      exit 1
    fi

    # better-sqlite3 v13 ships NAPI prebuilds for every platform, but they are
    # linked against a non-Nix glibc/libstdc++. Rebuild from source and replace
    # the linux-x64 prebuild, which is what lib/binding.js resolves first.
    for f in $(find -path '*/node_modules/better-sqlite3' -type d); do
      (cd "$f" && (
      npm run build-release --offline --nodedir="${nodeSources}"
      find build -type f -exec \
        ${lib.getExe removeReferencesTo} \
        -t "${nodeSources}" {} \;
      mkdir -p prebuilds
      cp -f build/Release/better_sqlite3.node prebuilds/linux-x64.node
      ))
    done

    # The checked-out Align prebuilds may be Git LFS pointer files. Rebuild
    # the native addon against the Nix toolchain and replace the x86-64
    # prebuild with the resulting binary.
    (
      cd libraries/align
      npm_config_nodedir="${nodeSources}" yarn node-gyp rebuild

      ${lib.getExe removeReferencesTo} \
        -t "${nodeSources}" \
        build/Release/error_align_native.node

      mkdir -p prebuilds/linux-x64
      cp -f \
        build/Release/error_align_native.node \
        prebuilds/linux-x64/@storyteller-platform+align.node
    )
  '';

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export NODE_ENV=production
    export NEXT_TELEMETRY_DISABLED=1
    export CI_COMMIT_TAG=web-v${finalAttrs.version}
    export npm_config_cache="$TMPDIR/.npm-cache"
    mkdir -p "$npm_config_cache"
    # Native bindings used while building the worker and Next.js application
    export SQLITE_NATIVE_BINDING="$PWD/node_modules/better-sqlite3/prebuilds/linux-x64.node"
    export ERROR_ALIGN_NATIVE_BINDING="$PWD/libraries/align"
    # Do the build! mlx-audio omits typescript from its devDependencies, so its
    # own build has no tsc; ghost-story's `tsc -b` builds it as a reference.
    yarn workspaces foreach -Rpt --from @storyteller-platform/web \
      --exclude @storyteller-platform/mlx-audio run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/{bin,lib/storyteller}
    # Standalone Next.js output
    if [[ ! -d applications/web/.next/standalone ]]; then
      echo "ERROR: Next.js standalone output not found"
      exit 1
    fi
    cp -r applications/web/.next/standalone/. $out/lib/storyteller/
    mkdir -p $out/lib/storyteller/applications/web/public
    cp -r applications/web/public/. $out/lib/storyteller/applications/web/public/
    mkdir -p $out/lib/storyteller/applications/web/.next/static
    cp -r applications/web/.next/static/. $out/lib/storyteller/applications/web/.next/static/
    # Migrations
    cp -r applications/web/migrations $out/lib/storyteller/applications/web/migrations
    # Scripts
    mkdir -p $out/lib/storyteller/applications/web/scripts
    cp -r scripts/. $out/lib/storyteller/applications/web/scripts/
    cp -r docker-scripts/. $out/lib/storyteller/applications/web/scripts/
    # Workers
    cp -r applications/web/work-dist $out/lib/storyteller/applications/web/work-dist
    cp -r applications/web/file-write-dist $out/lib/storyteller/applications/web/file-write-dist
    # Align
    mkdir -p $out/lib/storyteller/applications/web/work-dist/@storyteller-platform/align/prebuilds/linux-x64
    cp -r libraries/align/prebuilds/linux-x64/. \
      $out/lib/storyteller/applications/web/work-dist/@storyteller-platform/align/prebuilds/linux-x64/
    # Echogarden wasm
    cp node_modules/@echogarden/icu-segmentation-wasm/wasm/*.wasm \
      $out/lib/storyteller/applications/web/work-dist/
    # EPUBCheck
    mkdir -p $out/lib/storyteller/applications/web/work-dist/vendors
    cp -r libraries/epub/vendors/epubcheck-${epubcheckVersion} \
      $out/lib/storyteller/applications/web/work-dist/vendors/
    # Extract whisper.cpp version from ghost-story source
    whisperCppUpstreamVersion=$(grep -oP 'WHISPER_CPP_UPSTREAM_VERSION\s*=\s*"\K[^"]+' libraries/ghost-story/src/constants.ts)
    whisperCppPatchLevel=$(grep -oP 'WHISPER_CPP_PATCH_LEVEL\s*=\s*\K[0-9]+' libraries/ghost-story/src/constants.ts)
    whisperCppVersion="''${whisperCppUpstreamVersion}-st.''${whisperCppPatchLevel}"
    # Next.js traces better-sqlite3/prebuilds/** wholesale; keep the Nix-built
    # linux-x64 binding and drop upstream's foreign-platform binaries
    sqlitePrebuilds=$out/lib/storyteller/node_modules/better-sqlite3/prebuilds
    if [[ ! -f $sqlitePrebuilds/linux-x64.node ]]; then
      echo "ERROR: traced better-sqlite3 prebuild missing at $sqlitePrebuilds/linux-x64.node"
      exit 1
    fi
    find $sqlitePrebuilds -type f ! -name linux-x64.node -delete
    find $sqlitePrebuilds -type d -empty -delete
    # nodekit's prebuild links the distro's libcurl, libxml2 (the .so.2 soname,
    # which nixpkgs' default 2.15 no longer provides) and zlib
    patchelf --add-rpath ${lib.makeLibraryPath [ curl libxml2_13 zlib ]} \
      $out/lib/storyteller/node_modules/@storyteller-platform/nodekit-linux-x64-gnu/nodekit.linux-x64-gnu.node
    # Wrapper
    makeWrapper ${nodejs_26}/bin/node $out/bin/storyteller \
      --add-flags "--enable-source-maps $out/lib/storyteller/applications/web/server.js" \
      --chdir "$out/lib/storyteller/applications/web" \
      --run "WHISPER_DIR=\"\$HOME/.local/share/ghost-story/whisper-cpp/$whisperCppVersion/linux-x64-vulkan/bin\"; mkdir -p \"\$WHISPER_DIR\"; ln -sfn ${lib.getExe whisper} \"\$WHISPER_DIR/whisper-cli\"" \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg readium-cli ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ vulkan-loader ]} \
      --set NODE_ENV "production" \
      --set NEXT_TELEMETRY_DISABLED "1" \
      --set CI_COMMIT_TAG "web-v${finalAttrs.version}" \
      --set STORYTELLER_WHISPER_VARIANT "linux-x64-vulkan" \
      --set STORYTELLER_WORKER "worker.mjs" \
      --set STORYTELLER_FILE_WRITE_WORKER "fileWriteWorker.mjs" \
      --set SQLITE_NATIVE_BINDING "$out/lib/storyteller/node_modules/better-sqlite3/prebuilds/linux-x64.node" \
      --set ERROR_ALIGN_NATIVE_BINDING "$out/lib/storyteller/applications/web/work-dist/@storyteller-platform/align"
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted platform for synced audiobook/ebook reading";
    homepage = "https://storyteller-platform.gitlab.io/storyteller/";
    changelog = "https://gitlab.com/storyteller-platform/storyteller/-/releases/web-v${finalAttrs.version}";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "storyteller";
  };
})
