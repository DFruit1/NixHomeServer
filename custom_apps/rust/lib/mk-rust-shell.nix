{ craneLib, toolchain, ... }:

{ name ? "rust"
, checks ? { }
, extraPackages ? [ ]
, extraEnv ? { }
, shellHook ? ""
,
}:
let
  # Keep a persistent target dir under the user's cache and force incremental
  # compilation for the dev profile, so `cargo build` / `cargo clippy` inside
  # `nix develop` stay incremental across sessions instead of rebuilding the
  # whole crate graph from scratch on every edit.
  home = builtins.getEnv "HOME";
  cacheRoot = if home == "" then "/root" else home;
in
craneLib.devShell {
  inherit checks shellHook;
  name = "${name}-dev-shell";
  packages = toolchain ++ extraPackages;
  env = extraEnv // {
    CARGO_INCREMENTAL = "1";
    CARGO_PROFILE_DEV_INCREMENTAL = "1";
    CARGO_BUILD_TARGET_DIR = "${cacheRoot}/.cache/nixhomeserver-cargo/${name}";
  };
}
