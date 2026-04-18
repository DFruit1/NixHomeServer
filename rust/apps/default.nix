{ lib, pkgs, rustLib }:

{
  mail-archive-ui = import ./mail-archive-ui {
    inherit lib pkgs rustLib;
  };
}
