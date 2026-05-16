{ lib, ... }:

# Keep the template host aligned with the copyable root example.
import ../../vars.example.nix { inherit lib; }
