{ lib
, stdenvNoCC
, nodejs
, pnpm
, fetchPnpmDeps
, pnpmConfigHook
, makeWrapper
, sqlite
,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "youtube-downloader";
  version = "0.1.0";

  src = ./.;

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
    sqlite
  ];

  CI = "true";

  buildPhase = ''
    runHook preBuild
    pnpm run build
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
