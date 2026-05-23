{ config, lib, ... }:

{
  systemd.services.paperless-storage-layout-v1 = {
    before = [ "copyparty.service" ];
    script = lib.mkAfter ''
      install -d -m 0700 -o copyparty -g copyparty '${config.repo.paperless.paths.archive}/.hist'
    '';
  };
}
