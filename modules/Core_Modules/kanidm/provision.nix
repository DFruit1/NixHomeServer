{ config, lib, vars, ... }:

let
  identityCfg = config.repo.identity;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  mkManualGroup =
    members:
    {
      inherit members;
      overwriteMembers = false;
    };
  renderGroup = _: group: {
    members = group.members;
    overwriteMembers = group.overwriteMembers;
  };
  renderOauth2Client = _: client:
    {
      inherit (client)
        displayName
        originUrl
        basicSecretFile
        preferShortUsername
        scopeMaps
        supplementaryScopeMaps
        claimMaps
        ;
    }
    // lib.optionalAttrs (client.imageFile != null) {
      imageFile = client.imageFile;
    }
    // lib.optionalAttrs (client.originLanding != null) {
      originLanding = client.originLanding;
    };
in
{
  services.kanidm.provision = {
    enable = true;
    idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
    adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
    instanceUrl = kanidmCliUrl;

    persons.${vars.kanidmAdminUser} = {
      displayName = vars.kanidmAdminUser;
      mailAddresses = [ vars.kanidmAdminEmail ];
    };

    groups =
      {
        # Keep the builtin group in the provision inventory so post-start
        # reconciliation does not try to delete it as an orphaned entity.
        "domain_admins" = mkManualGroup [ ];
        "app-admin" = mkManualGroup [ vars.kanidmAdminUser ];
        users = mkManualGroup [ vars.kanidmAdminUser ];
      }
      // builtins.mapAttrs renderGroup identityCfg.groups;

    systems.oauth2 = builtins.mapAttrs renderOauth2Client identityCfg.oauth2Clients;
  };
}
