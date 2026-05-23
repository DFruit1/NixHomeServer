{ config, lib, vars, ... }:

let
  mkLocalBackend = path: {
    type = "local";
    inherit path;
    password = "{{ .ENV_LOCAL_BACKEND_SECRET }}";
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf
      (
        config.nixhomeserver.apps.files.enable
        && !config.nixhomeserver.apps.copyparty.enable
      )
      {
        repo.identity.groups."user-files" = {
          owner = "files";
          members = [ vars.kanidmAdminUser ];
        };
      })
    (lib.mkIf
      (
        config.nixhomeserver.apps.files.enable
        && config.nixhomeserver.apps.copyparty.enable
      )
      {
        users.users.filestash.extraGroups = lib.mkAfter [ "upload-review" ];

        services.filestash.settings = {
          middleware.attribute_mapping = {
            related_backend = lib.mkForce "Personal,Shared,Quarantine";
            params = lib.mkForce (builtins.toJSON {
              Personal = mkLocalBackend vars.usersRoot;
              Shared = mkLocalBackend vars.sharedRoot;
              Quarantine = mkLocalBackend vars.uploadSecurity.quarantineRoot;
            });
          };
          connections = lib.mkForce [
            {
              type = "local";
              label = "Personal";
              path = vars.usersRoot;
            }
            {
              type = "local";
              label = "Shared";
              path = vars.sharedRoot;
            }
            {
              type = "local";
              label = "Quarantine";
              path = vars.uploadSecurity.quarantineRoot;
            }
          ];
        };

        systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
          vars.uploadSecurity.quarantineRoot
        ];
      })
  ];
}
