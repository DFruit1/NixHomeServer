{ lib, ... }:

# The current/default deployment intentionally keeps operator-facing values in
# the repo-root vars.nix so admins can still configure the main install in one
# place. The host layer imports it to participate in the reusable template
# structure without splitting the active site's settings.
import ../../vars.nix { inherit lib; }
