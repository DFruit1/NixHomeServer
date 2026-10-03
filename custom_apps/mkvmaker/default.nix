{ lib, pkgs, rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  # The stock, unmodified nixpkgs tool packages already ship every executable
  # mkvmaker drives: HandBrakeCLI (with its HandBrake-patched ffprobe under
  # `ffmpeg-hb`) and mkvpropedit. Consuming them directly keeps the app on
  # substitutable upstream outputs instead of bespoke derivations that must be
  # compiled on every machine that lacks them in a local cache. The GTK GUI that
  # ships with stock `handbrake` is never invoked headlessly; see ADR 0002 for
  # the measured closure cost of accepting it.
  handbrakeCli = pkgs.handbrake;
  mkvpropedit = pkgs.mkvtoolnix-cli;
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
  # Exposed so tests (and operators reading `nix eval`) can assert exactly which
  # tool executables this app resolves to without rebuilding the Rust app.
  tools = {
    inherit handbrakeCli mkvpropedit;
    ffprobe = handbrakeCli.ffmpeg-hb;
  };
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
