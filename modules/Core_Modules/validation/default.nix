{ config, lib, vars, ... }:

let
  allowPlaceholders = vars.validation.allowPlaceholders or false;
  containsChangeMe = value: lib.hasInfix "CHANGE_ME" (toString value);
  externallyBoundPorts = lib.filterAttrs (name: _: !(lib.hasSuffix "Container" name)) vars.networking.ports;
  portValues = lib.attrValues externallyBoundPorts;
  uniquePortValues = lib.unique portValues;
  caddyHosts = builtins.attrNames config.services.caddy.virtualHosts;
  cloudflareHosts = builtins.attrNames config.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
  privateDnsHosts = config.services.unbound.privateHosts;
  privateDnsHostNames = builtins.attrNames privateDnsHosts;
  coreHosts = [
    vars.domain
    "www.${vars.domain}"
    vars.kanidmDomain
  ];
  invalidHostNames =
    lib.filter
      (name:
        name == ""
        || lib.hasInfix "://" name
        || lib.hasInfix "/" name
        || lib.hasInfix ":" name)
      (caddyHosts ++ cloudflareHosts ++ privateDnsHostNames);
  offDomainAppHosts =
    lib.filter
      (name: !(builtins.elem name coreHosts) && !(lib.hasSuffix ".${vars.domain}" name))
      caddyHosts;
  cloudflareWithoutCaddy =
    lib.filter
      (name: !(builtins.hasAttr name config.services.caddy.virtualHosts))
      cloudflareHosts;
  invalidDnsHosts =
    lib.filter
      (name:
        let
          host = privateDnsHosts.${name};
        in
        !host.publishOnLan && !host.publishOnNetbird)
      privateDnsHostNames;
  toList = value: if builtins.isList value then value else [ value ];
  oauth2Clients = config.services.kanidm.provision.systems.oauth2;
  oauth2ClientNames = builtins.attrNames oauth2Clients;
  oauth2UrlValues = client:
    (toList client.originUrl)
    ++ lib.optional ((client.originLanding or null) != null) client.originLanding
    ++ (client.redirects or [ ]);
  insecureOauth2Urls = lib.concatMap
    (name:
      let
        client = oauth2Clients.${name};
      in
      lib.optionals (!(client.allowInsecureUrls or false))
        (map
          (url: "${name}: ${url}")
          (lib.filter (url: !(lib.hasPrefix "https://" url)) (oauth2UrlValues client))))
    oauth2ClientNames;
  hostIdChars = lib.stringToCharacters vars.hostId;
  hexChars = lib.stringToCharacters "0123456789abcdef";
  validHostId =
    builtins.stringLength vars.hostId == 8
    && lib.all (char: builtins.elem char hexChars) hostIdChars;
in
{
  assertions = [
    {
      assertion = allowPlaceholders || vars.domain != "example.test";
      message = "nixhomeserver: replace the example domain before using this host for install/deploy.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.serverSSHPubKey;
      message = "nixhomeserver: replace serverSSHPubKey with a real SSH public key.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.netIface;
      message = "nixhomeserver: replace the LAN interface placeholder.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.mainDisk;
      message = "nixhomeserver: replace mainDisk with a /dev/disk/by-id basename.";
    }
    {
      assertion = allowPlaceholders || !(lib.any containsChangeMe vars.zfsDataPoolDiskIds);
      message = "nixhomeserver: replace all ZFS data-pool disk placeholders.";
    }
    {
      assertion = allowPlaceholders || vars.hostId != "00000000";
      message = "nixhomeserver: replace the example hostId with a stable 8-character hexadecimal value.";
    }
    {
      assertion = validHostId;
      message = "nixhomeserver: system.hostId must be exactly 8 lowercase hexadecimal characters.";
    }
    {
      assertion = builtins.elem vars.dnsMode [ "split-horizon" "netbird-only" ];
      message = "nixhomeserver: dnsMode must be either split-horizon or netbird-only.";
    }
    {
      assertion = builtins.length portValues == builtins.length uniquePortValues;
      message = "nixhomeserver: vars.networking.ports contains duplicate port values.";
    }
    {
      assertion = invalidHostNames == [ ];
      message = "nixhomeserver: host names must be bare hostnames without scheme, path, or port: ${lib.concatStringsSep ", " invalidHostNames}";
    }
    {
      assertion = offDomainAppHosts == [ ];
      message = "nixhomeserver: app Caddy hosts must live under ${vars.domain}: ${lib.concatStringsSep ", " offDomainAppHosts}";
    }
    {
      assertion = cloudflareWithoutCaddy == [ ];
      message = "nixhomeserver: Cloudflare ingress entries need matching Caddy virtual hosts: ${lib.concatStringsSep ", " cloudflareWithoutCaddy}";
    }
    {
      assertion = invalidDnsHosts == [ ];
      message = "nixhomeserver: private DNS hosts must publish on LAN, NetBird, or both: ${lib.concatStringsSep ", " invalidDnsHosts}";
    }
    {
      assertion = insecureOauth2Urls == [ ];
      message = "nixhomeserver: OAuth2 URLs must use https unless allowInsecureUrls is set: ${lib.concatStringsSep "; " insecureOauth2Urls}";
    }
  ];
}
