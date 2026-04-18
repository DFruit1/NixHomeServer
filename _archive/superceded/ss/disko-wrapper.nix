# disko-wrapper.nix  (all it does is supply vars + lib)
let
  lib  = import <nixpkgs/lib> {};
  vars = import ./vars.nix {};
in
  import ./disko.nix { inherit lib vars; }
