{ lib, config, vars, copyparty, ... }:

{
  imports = [ copyparty.nixosModules.default ];

  nixpkgs.overlays = [ copyparty.overlays.default ];

  services.copyparty = {
    enable = true;
    openFilesLimit = 8192;
    settings = {
      i = "127.0.0.1";
      p = vars.copypartyPort;
      no-reload = true;
    };
    volumes = {
      "/" = {
        path = "${vars.dataRoot}/copyparty";
        access.wG = "*";
      };
    };
  };
}
