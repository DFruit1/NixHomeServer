{ pkgs, ... }:

{
  homepage = pkgs.callPackage ./homepage { };
  youtube-downloader = pkgs.callPackage ./youtube-downloader { };
}
