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
    name = "homepage-production-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${sourcePath}/" (toString path);
        excludedPrefixes = [
          "node_modules"
          "dist"
          "coverage"
          "test-results"
          "tests/e2e"
        ];
        excluded = lib.any
          (prefix: rel == prefix || lib.hasPrefix "${prefix}/" rel)
          excludedPrefixes;
      in
      lib.cleanSourceFilter path type && !excluded;
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "homepage";
  version = "0.1.0";

  inherit src;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-SP2WZUkRAj32GBjwXgnhjfKD1t+qr3XXAsDiZaAviaU=";
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
    pnpm run build
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    pnpm run check
    test -f dist/server/entry.node-server.js || {
      echo "homepage server build did not produce dist/server/entry.node-server.js" >&2
      exit 1
    }
    test -f dist/client/q-manifest.json || {
      echo "homepage client build did not produce dist/client/q-manifest.json" >&2
      exit 1
    }
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/homepage" "$out/share/homepage" "$out/bin"
    cp -R dist/server "$out/lib/homepage/server"
    cp -R dist/client "$out/share/homepage/client"

    makeWrapper ${nodejs}/bin/node "$out/bin/homepage" \
      --add-flags "$out/lib/homepage/server/entry.node-server.js" \
      --set-default HOMEPAGE_STATIC_DIR "$out/share/homepage/client"

    runHook postInstall
  '';

  meta = {
    description = "Kanidm-authenticated home page for NixHomeServer users";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "homepage";
  };
})
