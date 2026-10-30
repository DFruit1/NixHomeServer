{ lib, buildNpmPackage, importNpmLock, makeWrapper, nodejs, stdenv, curl, zlib, libuuid, openssl }:

buildNpmPackage {
  pname = "media-manager-eye";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type: lib.cleanSourceFilter path type && builtins.baseNameOf path != "node_modules";
  };
  npmDeps = importNpmLock { npmRoot = ./.; };
  npmConfigHook = importNpmLock.npmConfigHook;
  npmFlags = [ "--ignore-scripts" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/media-manager-eye" "$out/bin"
    cp -r node_modules package.json server.mjs "$out/lib/media-manager-eye/"
    makeWrapper ${nodejs}/bin/node "$out/bin/media-manager-eye" \
      --add-flags "$out/lib/media-manager-eye/server.mjs" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib curl zlib libuuid openssl ]}
    runHook postInstall
  '';
  meta = {
    description = "Private EYE image analysis helper for Media Manager";
    mainProgram = "media-manager-eye";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
