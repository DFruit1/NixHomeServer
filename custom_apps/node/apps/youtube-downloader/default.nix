{ lib
, stdenvNoCC
, nodejs
, pnpm
, fetchPnpmDeps
, pnpmConfigHook
, makeWrapper
,
}:

let
  sourcePath = toString ./.;
  src = lib.cleanSourceWith {
    src = ./.;
    name = "youtube-downloader-production-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${sourcePath}/" (toString path);
        excludedPrefixes = [ "node_modules" "dist" "coverage" "test-results" ];
        excluded = lib.any
          (prefix: rel == prefix || lib.hasPrefix "${prefix}/" rel)
          excludedPrefixes;
      in
      lib.cleanSourceFilter path type && !excluded;
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "youtube-downloader";
  version = "0.1.0";

  inherit src;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-cjG6fSRnbfEQS1Wklweur9g148U0SRiEL8hfYKvAcTA=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
    makeWrapper
  ];

  CI = "true";

  buildPhase = ''
    runHook preBuild
    pnpm run build:client >"$TMPDIR/youtube-client-build.log" 2>&1 &
    client_pid=$!
    pnpm run build:server >"$TMPDIR/youtube-server-build.log" 2>&1 &
    server_pid=$!
    cleanup_builds() {
      kill "$client_pid" "$server_pid" 2>/dev/null || true
    }
    trap cleanup_builds EXIT INT TERM
    client_status=0
    server_status=0
    wait "$client_pid" || client_status=$?
    wait "$server_pid" || server_status=$?
    cat "$TMPDIR/youtube-client-build.log" "$TMPDIR/youtube-server-build.log"
    trap - EXIT INT TERM
    if ((client_status != 0 || server_status != 0)); then
      exit 1
    fi
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    pnpm run check
    test -f dist/client/index.html || {
      echo "youtube-downloader client build did not produce dist/client/index.html" >&2
      exit 1
    }
    test -f dist/client/q-manifest.json || {
      echo "youtube-downloader client build did not produce dist/client/q-manifest.json" >&2
      exit 1
    }
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/youtube-downloader" "$out/share/youtube-downloader" "$out/bin"
    cp -R dist/server "$out/lib/youtube-downloader/server"
    cp -R dist/client "$out/share/youtube-downloader/client"

    makeWrapper ${nodejs}/bin/node "$out/bin/youtube-downloader" \
      --add-flags "$out/lib/youtube-downloader/server/server/index.js" \
      --set-default YOUTUBE_DOWNLOADER_STATIC_DIR "$out/share/youtube-downloader/client"

    runHook postInstall
  '';

  meta = {
    description = "Authenticated yt-dlp web UI for NixHomeServer media downloads";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "youtube-downloader";
  };
})
