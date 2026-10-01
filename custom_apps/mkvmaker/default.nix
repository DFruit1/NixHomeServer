{ lib, pkgs, rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  handbrakeCli = pkgs.handbrake.override { useGtk = false; };
  mkvpropedit = pkgs.mkvtoolnix-cli.overrideAttrs (_old: {
    pname = "mkvpropedit";
    buildPhase = ''
      runHook preBuild
      rake apps:mkvpropedit
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 src/mkvpropedit "$out/bin/mkvpropedit"
      runHook postInstall
    '';
    doCheck = false;
  });
  app = rustLib.mkRustApp {
    name = "mkvmaker";
    packageName = "disc-to-jellyfin";
    binaryName = "disc-to-jellyfin";
    srcDir = ./.;
    modulePath = ../../modules/mkvmaker;
    version = workspaceVersion;
    inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
    meta = {
      description = "Automated DVD ISO to Jellyfin-ready MKV converter";
      license = lib.licenses.mit;
    };
  };
in
app // {
  backendPackage = app.package;
  package = rustLib.assembleRuntimePackage {
    name = "mkvmaker";
    backendPackage = app.package;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    extraInstallCommands = ''
      mkdir -p "$out/libexec/mkvmaker"
      cp ${./auto_import.py} "$out/libexec/mkvmaker/auto_import.py"
      wrapProgram "$out/bin/disc-to-jellyfin" \
        --set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI" \
        --set-default DISC_TO_JELLYFIN_FFPROBE "${handbrakeCli.ffmpeg-hb}/bin/ffprobe" \
        --set-default DISC_TO_JELLYFIN_MKVPROPEDIT "${mkvpropedit}/bin/mkvpropedit"
      makeWrapper ${pkgs.python3}/bin/python3 "$out/bin/mkvmaker-auto-import" \
        --add-flags "$out/libexec/mkvmaker/auto_import.py" \
        --set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI" \
        --set-default DISC_TO_JELLYFIN_FFPROBE "${handbrakeCli.ffmpeg-hb}/bin/ffprobe"
    '';
  };
}
