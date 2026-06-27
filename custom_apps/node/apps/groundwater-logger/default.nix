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
  pname = "groundwater-logger";
  version = "0.1.0";

  src = ./.;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-/XxrK+IDjACUNW09m4r36uR/XCA94+0CmjygLuuLC+o=";
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
    test -f dist/server/entry.node-server.js || {
      echo "groundwater-logger server build did not produce dist/server/entry.node-server.js" >&2
      exit 1
    }
    test -f dist/client/q-manifest.json || {
      echo "groundwater-logger client build did not produce dist/client/q-manifest.json" >&2
      exit 1
    }
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/groundwater-logger" "$out/share/groundwater-logger" "$out/bin"
    cp -R dist/server "$out/lib/groundwater-logger/server"
    cp -R dist/client "$out/share/groundwater-logger/client"

    makeWrapper ${nodejs}/bin/node "$out/bin/groundwater-logger" \
      --add-flags "$out/lib/groundwater-logger/server/entry.node-server.js" \
      --set-default GROUNDWATER_LOGGER_STATIC_DIR "$out/share/groundwater-logger/client"

    runHook postInstall
  '';

  meta = {
    description = "LAN MQTT test console for a groundwater level logger";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "groundwater-logger";
  };
})
