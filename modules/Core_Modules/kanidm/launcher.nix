{ config, lib, pkgs, ... }:

let
  # Browser clients only. Native clients still authenticate but must not add a
  # second launcher (or send users to an API). The shared gateway is not an app.
  homepageCards = {
    abs-web = "audiobooks";
    browsertrix-downloader-web = "archives";
    calibre-web-web = "calibre";
    chaptarr-web = "chaptarr";
    filestash-web = "files";
    forgejo-web = "git";
    freshrss-web = "feeds";
    immich-web = "photos";
    jellyfin-web = "videos";
    kavita-web = "books";
    kiwix-web = "wiki";
    kopia-web = "kopia";
    langfuse = "langfuse";
    mail-archive-web = "emails";
    media-manager-web = "media-manager";
    opencloud-web = "cloud";
    paperless-web = "documents";
    prowlarr-web = "prowlarr";
    qbittorrent-web = "torrents";
    radarr-web = "radarr";
    sonarr-web = "sonarr";
    youtube-downloader-web = "downloads";
  };
  cards = config.repo.homepage.serviceCards;
  cardFor = id: lib.findFirst (card: card.id == id) null cards;
  registeredClients = lib.filterAttrs
    (_: id: let card = cardFor id; in card != null && card.enabled)
    homepageCards;
  clients = config.services.kanidm.provision.systems.oauth2;
  visibleClients = [ "homepage-web" ] ++ builtins.attrNames (lib.filterAttrs
    (name: _: clients.${name}.present or true)
    registeredClients);
  visibleImages = lib.concatMapStringsSep ", "
    (name: "img[id=${builtins.toJSON name}]") visibleClients;
  launcherCss = pkgs.writeText "kanidm-override.css" ''
    ${builtins.readFile ./override.css}

    /* Kanidm 1.11 apps_partial.html: hide the whole column, including its
       keyboard target. Listing-only: do not alter OAuth clients or scopes.
       The allowlist also hides retained clients from uninstalled apps. */
    main .row > div:has(> .card .oauth2-img):not(:has(:is(${visibleImages}))) {
      display: none;
    }
  '';
in
{
  services.kanidm.provision.systems.oauth2 = lib.mapAttrs
    (_: id: let card = cardFor id; in {
      displayName = lib.mkForce card.name;
      # Keep the approved Homepage assets as the source, rather than a copy.
      imageFile = lib.mkForce (../../../custom_apps/node/apps/homepage/public
        + card.logoUrl);
    }) registeredClients;

  systemd.services.kanidm.serviceConfig.BindReadOnlyPaths = [
    "${launcherCss}:${config.services.kanidm.package}/ui/hpkg/override.css"
  ];
}
