{ config, vars, ... }:

let
  host = "archives.${vars.domain}";
in
{
  users.groups.browsertrix-downloader = { };
  # Service-only primary group: do not add NSS members. The rollback closure
  # grants Search the legacy group, but never this private group.
  users.groups.browsertrix-private = { };

  users.users.browsertrix-downloader = {
    isSystemUser = true;
    group = "browsertrix-downloader";
    home = "/var/lib/browsertrix-downloader";
    createHome = false;
  };

  users.users.browsertrix-downloader-worker = {
    isSystemUser = true;
    group = "browsertrix-downloader";
    home = config.repo.browsertrixDownloader.paths.workerHome;
    createHome = false;
    autoSubUidGidRange = true;
  };

  services.kanidm.provision = {
    groups."web-archive-users".members = vars.kanidmAppUsers;

    systems.oauth2.browsertrix-downloader-web = {
      displayName = "Web Archives";
      imageFile = ../Core_Modules/kanidm/assets/documents.svg;
      originUrl = "https://${host}/oauth2/callback";
      originLanding = "https://${host}";
      basicSecretFile = config.age.secrets.browsertrixDownloaderOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps."web-archive-users" = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
