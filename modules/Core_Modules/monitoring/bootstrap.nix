{ config, lib, ... }:

let
  requiredSecrets = [
    "monitorOauth2ProxyClientSecret"
    "monitorOauth2ProxyCookieSecret"
    "beszelHubEnv"
  ];

  missingSecrets = lib.filter (name: !(builtins.hasAttr name config.age.secrets)) requiredSecrets;
in
{
  assertions = [
    {
      assertion = missingSecrets == [ ];
      message = "Monitoring requires missing age secrets: ${lib.concatStringsSep ", " missingSecrets}";
    }
  ];
}
