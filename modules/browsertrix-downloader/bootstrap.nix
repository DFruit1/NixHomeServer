{ config, ... }:

let
  repoRoot = ../..;
  ageHeader = "-----BEGIN AGE ENCRYPTED FILE-----";
  mkSecretAssertions = secretNames:
    map
      (name:
        let
          secretPath = repoRoot + "/secrets/${name}.age";
          content = if builtins.pathExists secretPath then builtins.readFile secretPath else "";
        in
        {
          assertion =
            builtins.hasAttr name config.age.secrets
            && builtins.pathExists secretPath
            && content != ""
            && builtins.substring 0 (builtins.stringLength ageHeader) content == ageHeader;
          message = "Missing or invalid agenix secret '${name}'. Expected secrets/${name}.age to be valid encrypted content; use nix run .#generate-secrets -- --identity /path/to/current/age.key.";
        })
      secretNames;
in
{
  config.assertions = mkSecretAssertions [
    "browsertrixDownloaderOauth2ProxyClientSecret"
    "browsertrixDownloaderOauth2ProxyCookieSecret"
  ];
}
