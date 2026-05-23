{ pkgs, rustLib }:

{
  ops = pkgs.mkShell {
    name = "ops-dev-shell";
    packages = (with pkgs; [
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
    ]) ++ rustLib.toolchain;
  };
}
