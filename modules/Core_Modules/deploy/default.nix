# Core configuration for the guarded deploy surface: the private, owner-only
# target-side namespace that deployment archives are staged in.
#
# Archives are staged here instead of a general temporary directory so that an
# orphaned successful upload has a bounded lifetime that does not depend on the
# uploading SSH session surviving. base-system declares the tmpfiles expiry for
# this path; scripts/helpers/deploy-archive-cleanup.sh enforces the same path,
# owner-only mode, and entry-name shape on both ends of the transfer.

{ config, lib, ... }:

{
  options.repo.deploy = {
    archiveStagingDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixhomeserver-deploy/archive-staging";
      description = "Owner-only directory that deploy archives are staged in on the build/target host. Its contents are expired declaratively by systemd-tmpfiles so a successful upload orphaned by a lost SSH session cannot accumulate indefinitely.";
    };
  };

  config = lib.mkIf (
    config.repo.deploy.archiveStagingDir != "/var/lib/nixhomeserver-deploy/archive-staging"
  ) {
    assertions = [
      {
        assertion = builtins.match "/var/lib/nixhomeserver-deploy/[A-Za-z0-9][A-Za-z0-9._-]*" config.repo.deploy.archiveStagingDir != null;
        message = "nixhomeserver: repo.deploy.archiveStagingDir must be a single directory directly under /var/lib/nixhomeserver-deploy so expiry can never reach outside the deploy state directory: ${config.repo.deploy.archiveStagingDir}";
      }
    ];
  };
}
