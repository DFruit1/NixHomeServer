{ lib, ... }:

# Keep the template host aligned with the copyable root example.
let
  base = import ../../vars.example.nix { inherit lib; };
in
base // {
  validation = (base.validation or { }) // {
    allowPlaceholders = true;
  };
}
