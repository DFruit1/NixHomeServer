# First-party Apache Solr package.
#
# nixpkgs removed the Solr package and its NixOS module, so the Search
# platform vendors the official Apache binary distribution here. The tarball
# is self-contained (bundled Jetty); we only need to guarantee a JDK and the
# small Unix tools the `bin/solr` control script expects on PATH.
{
  lib,
  stdenv,
  fetchurl,
  jdk_headless,
  makeWrapper,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  procps,
  findutils,
  lsof,
}:

let
  solrVersion = "9.10.1";
in
stdenv.mkDerivation {
  pname = "solr";
  version = solrVersion;

  src = fetchurl {
    url = "https://archive.apache.org/dist/solr/solr/${solrVersion}/solr-${solrVersion}.tgz";
    hash = "sha256-Md2Rrq3lQPTXAFzBoffMWDrXenjYAMkGXKwGrxsJdFQ=";
  };

  # The distribution ships prebuilt jars; never strip or patch them.
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ jdk_headless ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r ./* $out
    runHook postInstall
  '';

  postInstall = ''
    wrapProgram "$out/bin/solr" --prefix PATH : "${
      lib.makeBinPath [
        jdk_headless
        coreutils
        gnugrep
        gawk
        gnused
        procps
        findutils
        lsof
      ]
    }"
  '';

  meta = {
    description = "Open enterprise search platform from the Apache Software Foundation";
    homepage = "https://solr.apache.org";
    license = lib.licenses.asl20;
    mainProgram = "solr";
    platforms = lib.platforms.unix;
  };
}
