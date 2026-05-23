{ lib, vars, ... }:

{
  systemd.services.paperless-storage-layout-v1.script = lib.mkAfter ''
    setfacl -x u:mail-archive-ui '${vars.paperlessInboxRoot}' 2>/dev/null || true
  '';
}
