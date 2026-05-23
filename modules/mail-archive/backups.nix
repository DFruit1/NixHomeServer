{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."mail-archive".enable { };
}
