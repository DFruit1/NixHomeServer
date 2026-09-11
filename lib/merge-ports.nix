{ lib }:

registrations:
lib.foldl'
  (ports: next:
  let
    duplicates = builtins.attrNames (builtins.intersectAttrs ports next);
    valid = builtins.all (port: builtins.isInt port && port > 0 && port <= 65535) (builtins.attrValues next);
  in
  assert lib.assertMsg valid "Application port registrations must contain integers between 1 and 65535.";
  assert lib.assertMsg (duplicates == [ ]) "Duplicate application port names: ${lib.concatStringsSep ", " duplicates}";
  ports // next)
{ }
  registrations
