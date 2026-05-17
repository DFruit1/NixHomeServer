{
  lib,
  stdenvNoCC,
  nodejs,
  pnpm,
  makeWrapper,
  sqlite,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "youtube-downloader";
  version = "0.1.0";

  src = ./.;

  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 2;
    hash = "sha256-f9m+sbm2/pZQa3am0DiwD+At/EKIVa3/ugt/sNg4t2U=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
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
