{ craneLib, toolchain, ... }:

{ name ? "rust"
, checks ? { }
, extraPackages ? [ ]
, extraEnv ? { }
, shellHook ? ""
,
}:
craneLib.devShell (
  {
    inherit checks shellHook;
    name = "${name}-dev-shell";
    packages = toolchain ++ extraPackages;
  }
    // extraEnv
)
