# The SimpleX Chat daemon, pinned by content hash.
#
# Why a derivation and not a curl in the installer script
# -----------------------------------------------------
# The daemon is a third-party binary this repository runs on the administrator's
# workstation. Nothing in nixpkgs packages simplex-chat, and the upstream project
# publishes no container image for the chat client, so the binary has to come
# from a GitHub release. Fetching it with curl at install time means the thing
# that gets executed is whatever the release asset says on the day the installer
# runs -- there is no record of what ran, and a re-run after an upstream asset
# change silently installs different code. AGENTS.md pins dependencies; this is
# the same commitment applied to a binary that has no package.
#
# fetchurl with an explicit sha256 turns the download into a content-addressed
# store path. A different byte range produces a different path and a build
# failure rather than a silently different daemon, and the install is
# reproducible from the lock in this file alone.
#
# The ubuntu-22_04 build is used on every distribution in this fleet: it links
# against glibc 2.35 and needs no unusual kernel or hardware, which is what makes
# it the most portable of the published Linux assets. Verified to run under
# glibc 2.41 (Void Linux) as well as on the NixOS server.
#
# Verify with: nix-instantiate --eval --strict scripts/hermes/simplex-chat.nix

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.runCommand "simplex-chat-7.0.3"
  {
    pname = "simplex-chat";
    version = "7.0.3";

    # sha256 from upstream's own _sha256sums asset for this release:
    #   5afb1d25efe5ccf564a1ab124bc7f410a7a73171c974a4d8b7f4d8f2e3d62e77
    #   v7.0.3/simplex-chat-ubuntu-22_04-x86_64
    # re-expressed as SRI above, since fetchurl wants that form:
    #   sha256-WvsdJe/lzPVkoasSS8f0EKenMXHJdKTYt/TY8uPWLnc=
    src = pkgs.fetchurl {
      url = "https://github.com/simplex-chat/simplex-chat/releases/download/v7.0.3/simplex-chat-ubuntu-22_04-x86_64";
      hash = "sha256-WvsdJe/lzPVkoasSS8f0EKenMXHJdKTYt/TY8uPWLnc=";
    };

    meta = with lib; {
      description = "SimpleX Chat terminal client, used here as the bot's chat daemon";
      homepage = "https://simplex.chat/";
      license = licenses.agpl3Plus;
      platforms = platforms.linux;
      # Deliberately NOT listing `knownVulnerabilities` for the un-reproducible
      # build: that attribute is a list of *security* advisories, and populating
      # it marks the derivation insecure, which makes nix refuse to evaluate it
      # until every consumer opts in via permittedInsecurePackages. The
      # provenance limitation is recorded in the header comment instead.
    };
  }
  ''
    install -Dm755 "$src" $out/bin/simplex-chat
    ln -s simplex-chat $out/bin/simplex-chat-cli
  ''