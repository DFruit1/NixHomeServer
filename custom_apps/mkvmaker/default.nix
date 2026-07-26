{ lib, pkgs, rustLib, ... }:

let
  handbrakeCli = pkgs.runCommand "handbrake-cli-${pkgs.handbrake.version}" { } ''
    mkdir -p "$out/bin"
    cp ${pkgs.handbrake}/bin/.HandBrakeCLI-wrapped "$out/bin/HandBrakeCLI"
  '';
  app = rustLib.mkRustApp {
    name = "mkvmaker";
    binaryName = "disc-to-jellyfin";
    srcDir = ./.;
    modulePath = ../../modules/mkvmaker;
    version = "0.3.0";
    extraSourcePrefixes = [ "auto_import.py" ];
    meta = {
      description = "Automated DVD ISO to Jellyfin-ready MKV converter";
      license = lib.licenses.mit;
    };
  };
in
app // {
  package = app.package.overrideAttrs (oldAttrs: {
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
    postInstall = (oldAttrs.postInstall or "") + ''
      mkdir -p "$out/libexec/mkvmaker"
      cp ${./auto_import.py} "$out/libexec/mkvmaker/auto_import.py"
      wrapProgram "$out/bin/disc-to-jellyfin" \
        --set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI" \
        --set-default DISC_TO_JELLYFIN_FFPROBE "${pkgs.handbrake.ffmpeg-hb}/bin/ffprobe"
      makeWrapper ${pkgs.python3}/bin/python3 "$out/bin/mkvmaker-auto-import" \
        --add-flags "$out/libexec/mkvmaker/auto_import.py" \
        --set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI" \
        --set-default DISC_TO_JELLYFIN_FFPROBE "${pkgs.handbrake.ffmpeg-hb}/bin/ffprobe"
    '';
  });
}
