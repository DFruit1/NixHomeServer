{ pkgs, ... }:

{
  youtube-downloader = pkgs.callPackage ./youtube-downloader { };
}
