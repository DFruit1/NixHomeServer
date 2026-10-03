# Core configuration for the guarded deploy surface: the private, owner-only
# target-side namespace that deployment archives are staged in.
#
# Archives are staged here instead of a general temporary directory so that an
# orphaned successful upload has a bounded lifetime that does not depend on the
# uploading SSH session surviving. base-system declares the tmpfiles expiry for
# this path; scripts/helpers/deploy-archive-cleanup.sh enforces the same path,
# owner-only mode, and entry-name shape on both ends of the transfer.

{ lib, ... }:

{
  options.repo.deploy.archiveStagingDir = lib.mkOption {
    type = lib.types.enum [ "/var/lib/nixhomeserver-deploy-archives" ];
    default = "/var/lib/nixhomeserver-deploy-archives";
    description = "Fixed owner-only archive namespace on every build host, outside root-only deploy transaction/stamp ancestry. Only this dedicated sibling is supported by the helper and the 48h systemd-tmpfiles expiry contract; arbitrary paths are not configurable.";
  };
}
