{ pkgs }:

with pkgs; [
  cargo
  cargo-nextest
  clippy
  rust-analyzer
  ripgrep
  rustc
  rustfmt
]
