# First-party ntfy server package.
#
# nixpkgs ships no ntfy server: `pkgs.ntfy` is the unrelated dschep Python CLI,
# `services.ntfy` does not exist in either pinned channel, and the only ntfy
# modules nixpkgs provides are `services.ntfy-sh` plus the Alertmanager and
# Grafana senders. The push API server is therefore built here from the upstream
# Go module.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule {
  pname = "ntfy-server";
  version = "2.28.0";

  # The upstream repository is binwiederhier/ntfy. binwieder/ntfy 404s.
  src = fetchFromGitHub {
    owner = "binwiederhier";
    repo = "ntfy";
    tag = "v2.28.0";
    hash = "sha256-Xlo0iuVd122kPpxK7aL4RBnR9gHLIpGj2nQSlBmMjYc=";
  };

  vendorHash = "sha256-+o1H3ok2B3zB0MxB5Vc7t69j2LOccyBHLVJSLcR9qFM=";

  # The committed vendor/ tree is stale against go.mod, so it is deleted rather
  # than reused. //go:embed docs and //go:embed site then require the
  # placeholder files upstream's Makefile creates from the built web
  # application; the server only needs them to satisfy the embed directives.
  postPatch = ''
    rm -rf vendor
    mkdir -p server/docs server/site
    touch server/docs/index.html server/site/app.html
  '';

  # The server's main package is the module root. subPackages = [ "server" ]
  # produces an empty output.
  subPackages = [ "." ];

  tags = [
    "sqlite_omit_load_extension"
    "osusergo"
    "netgo"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.version=v2.28.0"
    "-X"
    "main.commit=10cb650"
  ];

  # Upstream's test suite needs a running server and a writable cache; the
  # module-system gate is the packaging, not ntfy's own integration tests.
  doCheck = false;

  meta = {
    description = "Self-hosted push notification server with a topic-based pub/sub API";
    homepage = "https://ntfy.sh";
    license = lib.licenses.asl20;
    mainProgram = "ntfy";
    platforms = lib.platforms.unix;
  };
}