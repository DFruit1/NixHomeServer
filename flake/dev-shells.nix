{ pkgs, pkgsUnstable, rustLib, vars }:

{
  youtube-downloader-tauri = import ../custom_apps/node/apps/youtube-downloader/tauri-dev-shell.nix {
    inherit pkgs pkgsUnstable;
  };

  filesync-tauri = import ../custom_apps/node/apps/youtube-downloader/tauri-dev-shell.nix {
    inherit pkgs pkgsUnstable;
    appName = "filesync";
    defaultServerUrl = "https://filesync-api.${vars.domain}";
  };

  filesync-android-emulator = import ../custom_apps/node/apps/filesync/android-emulator-shell.nix {
    inherit pkgs pkgsUnstable;
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
      stdenv.cc
    ]) ++ rustLib.toolchain;
  };

  # Evaluation-only shell for CI and lightweight `nix-eval-jobs` /
  # `nix flake check` runs. Omits the Rust toolchain so instantiating this shell
  # does not pull the compiler into the closure.
  eval = pkgs.mkShell {
    name = "eval-dev-shell";
    packages = (with pkgs; [
      jq
      nix-eval-jobs
      nix-output-monitor
      nix-tree
      ripgrep
    ]);
  };
}
