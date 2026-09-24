{ lib
, pkgs
, clientPackage
,
}:

let
  packageJson = builtins.fromJSON (builtins.readFile ./package.json);
in
pkgs.rustPlatform.buildRustPackage {
  pname = "youtube-downloader-tauri";
  inherit (packageJson) version;

  src = lib.cleanSource ./src-tauri;

  cargoLock.lockFile = ./src-tauri/Cargo.lock;

  nativeBuildInputs = with pkgs; [
    pkg-config
    wrapGAppsHook4
  ];

  buildInputs = with pkgs; [
    glib
    gtk3
    librsvg
    libsoup_3
    webkitgtk_4_1
  ];

  postPatch = ''
    mkdir -p ../dist
    cp -R ${clientPackage}/share/youtube-downloader/client ../dist/client
  '';

  doCheck = false;

  meta = {
    description = "Desktop and mobile Tauri shell for the NixHomeServer YouTube Downloader";
    license = lib.licenses.mit;
    mainProgram = "youtube-downloader";
  };
}
