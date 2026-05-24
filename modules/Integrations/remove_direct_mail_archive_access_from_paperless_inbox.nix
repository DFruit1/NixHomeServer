{ config, lib, ... }:

{
  systemd.services.paperless-storage-layout-v1.script = lib.mkAfter ''
    setfacl -x u:mail-archive-ui '${config.repo.paperless.paths.inbox}' 2>/dev/null || true
  '';
}
