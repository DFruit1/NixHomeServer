{ pkgs, ... }:

{
  groundwater-logger = pkgs.callPackage ./groundwater-logger { };
  homepage = pkgs.callPackage ./homepage { };
  youtube-downloader = pkgs.callPackage ./youtube-downloader { };
}
