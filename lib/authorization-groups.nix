{ lib }:

{ monitoringAccess }:

let
  nameValidation = import ./name-validation.nix { inherit lib; };
  configuredMonitoringGroup = monitoringAccess.group or null;
  renderableGroup = fallback: value:
    if nameValidation.validKanidmGroup value then value else fallback;
in
{
  inherit configuredMonitoringGroup;

  # Dynamic Nix attribute names must be valid strings before NixOS can report
  # assertions. These unmistakable placeholders keep malformed operator input
  # evaluable; central validation still rejects the original configured value.
  monitoringGroup = renderableGroup
    "invalid-monitoring-access-group"
    configuredMonitoringGroup;
}
