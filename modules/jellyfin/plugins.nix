{ lib, pkgs, ... }:

let
  mkPluginDrv = { pname, version, sha256 }:
    let
      slug = builtins.replaceStrings [ " " ] [ "-" ] (lib.toLower pname);
      pluginDirName = "${pname}_${version}";
    in
    {
      inherit pname version pluginDirName;
      drv = pkgs.stdenv.mkDerivation {
        name = "jellyfin-plugin-${slug}-${version}";
        src = pkgs.fetchurl {
          url = "https://repo.jellyfin.org/files/plugin/${slug}/${slug}_${version}.zip";
          inherit sha256;
        };
        nativeBuildInputs = [ pkgs.unzip ];
        unpackPhase = ''
          mkdir -p plugin
          unzip -q "$src" -d plugin
        '';
        installPhase = ''
          mkdir -p "$out/lib"
          cp -r plugin/* "$out/lib/"
        '';
        dontFixup = true;
      };
    };

  jellyfinMetadataPlugins = map mkPluginDrv [
    { pname = "TheTVDB";       version = "20.0.0.0"; sha256 = "sha256-bRezogPaI1o3MXdfY2V+ucNs/p++m+yUK40sTsGa82M="; }
    { pname = "Fanart";        version = "12.0.0.0"; sha256 = "sha256-CSJmiWD+dGTUFJaTthlNB+Wt/jxqeOofxGLDleKeF/Y="; }
    { pname = "TMDb Box Sets"; version = "12.0.0.0"; sha256 = "sha256-J5xYHv3xYOQeZNHkwbUAZ7Skd/x62KPaUQtSmTg1uhY="; }
    { pname = "Cover Art Archive"; version = "9.0.0.0"; sha256 = "sha256-Sb58zFwj27HxmMKP1VHuvRfeT2h7Kdza5M7LuXQqb8U="; }
    { pname = "AniDB";         version = "11.0.0.0"; sha256 = "sha256-SihyCHOlrTJOvneHyqNdH63615DVziV0VKwChDdJ6DA="; }
    { pname = "AniList";       version = "12.0.0.0"; sha256 = "sha256-XZnjWkoorNyBx2fN/0dnxH5Ui0eBmQsnZ5dFvDStRCc="; }
    { pname = "AniSearch";     version = "6.0.0.0";  sha256 = "sha256-govTIXXkkI33hGPZJ9+wt8sFa8K29pxdpJhqW5rAX4M="; }
    { pname = "Open Subtitles"; version = "23.0.0.0"; sha256 = "sha256-afXrFEkQm2lHkL0wtLhhQc9aNYCsaXyXbXuIujQHDtw="; }
    { pname = "Subtitle Extract"; version = "5.0.0.0"; sha256 = "sha256-KHCUPgwdCZCadK2qX10GJ+dfVBryljcx721crBC7dvc="; }
  ];
in
{
  _module.args = {
    inherit jellyfinMetadataPlugins;
  };
}
