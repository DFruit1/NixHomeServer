{ lib }:

path: parameters:
let
  text = builtins.readFile path;
  names = builtins.attrNames parameters;
  tokens = map (name: "@NIX_${name}@") names;
  required = lib.concatLists (builtins.filter builtins.isList (builtins.split "(@NIX_[A-Z0-9_]+@)" text));
  missing = builtins.filter (token: !(builtins.elem token tokens)) required;
in
assert lib.assertMsg (missing == [ ]) "Missing shell template parameters in ${toString path}: ${lib.concatStringsSep ", " missing}";
builtins.replaceStrings tokens (map (name: toString parameters.${name}) names) text
