{ config, lib, ... }:

{
  config = lib.mkIf config.repo.ntfy.enable {
    # Nothing to back up. ntfy holds a bounded message cache and expiring
    # attachments, both of which are deliberately lossy notification traffic
    # rather than records, and it uses no database on this host. Declaring an
    # appStateEntry here would make the backup system snapshot a cache that is
    # designed to be dropped.
  };
}