{ lib, pkgs, rustLib, rustApps }:

{
  rust = rustLib.mkRustShell {
    name = "rust";
  };

  ops = pkgs.mkShell {
    name = "ops-dev-shell";
    packages = with pkgs; [
      deadnix
      gitMinimal
      jq
      nix-output-monitor
      nix-tree
      nixpkgs-fmt
      nvd
      python3
      ripgrep
      shellcheck
      statix
    ];
  };
}
  // lib.mapAttrs (_: app: app.devShell) rustApps
