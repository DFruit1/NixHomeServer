{ config, lib, pkgs, ... }:

let
  cfg = config.repo.freshrss;
  # Upstream declares no LICENSE file, so this pin is treated as a fixed,
  # private-use input of this deployment rather than a redistributable package.
  afReadability = pkgs.freshrss-extensions.buildFreshRssExtension {
    FreshRssExtUniqueId = "Af_Readability";
    pname = "af-readability";
    version = "0.5-unstable-2026-08-11";
    src = pkgs.fetchFromGitHub {
      owner = "Niehztog";
      repo = "freshrss-af-readability";
      rev = "7e0dc8fd82d5f13863e5121cbe0f7b1f2d194fd9";
      hash = "sha256-lfUZOwLqAzoiUyqSLIe+Q7mTq1clDsm3WhKMI5G8nGA=";
    };
    meta = {
      description = "FreshRSS extension that replaces the summary with the full article text for selected feeds using its bundled FiveFilters Readability.php library";
      homepage = "https://github.com/Niehztog/freshrss-af-readability";
    };
  };
in
{
  config = lib.mkIf cfg.enable {
    repo.freshrss.extensions = [ afReadability ];
  };
}
