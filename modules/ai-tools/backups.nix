{ ... }:

{
  # The MCP tool server holds no service state: SearXNG is queried live and
  # results are not persisted. Nothing to snapshot and nothing to retain on
  # removal.
  #
  # The ai-workspace directory does now persist written files, and that is
  # deliberate rather than an oversight. It lives on the ZFS data pool, which no
  # repo.backups.snapshotRoots entry covers (those are /persist and the Paperless
  # root), so it survives rebuilds without being backed up. Adding it here, or to
  # any snapshotRoot, would turn model scratch output into backup volume, which
  # is exactly what the owner declined. networking.nix asserts it stays outside
  # every snapshot root, so this comment is checked rather than merely claimed.
}
