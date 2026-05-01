{ pkgs }:

with pkgs; [
  cargo
  rustc
  clippy
  rustfmt
  rust-analyzer
  cargo-nextest
  ripgrep
]
