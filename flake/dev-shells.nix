{ pkgs, pkgsUnstable, rustLib }:

{
  youtube-downloader-tauri = import ../custom_apps/node/apps/youtube-downloader/tauri-dev-shell.nix {
    inherit pkgs pkgsUnstable rustLib;
  };

  ops = pkgs.mkShell {
    name = "ops-dev-shell";
    packages = (with pkgs; [
      deadnix
      gitMinimal
      jq
      nix-eval-jobs
      nix-output-monitor
      nix-tree
      nixpkgs-fmt
      nvd
      python3
      ripgrep
      shellcheck
      statix
    ]) ++ rustLib.toolchain;
  };
}
