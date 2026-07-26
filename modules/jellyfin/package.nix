{ lib, pkgs, ... }:

let
  pluginVersion = "1.0.8.0";
  localManifest = pkgs.writeText "jellyfin-oidc-meta.json" ''
    {
      "category": "Authentication",
      "changelog": "Pinned NixHomeServer build with strict ID-token validation and rollback-safe web-login styling.",
      "description": "OpenID Connect authentication with Quick Connect support.",
      "guid": "d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90",
      "name": "OIDC RBAC",
      "overview": "OpenID Connect login for existing Jellyfin accounts.",
      "owner": "Ezeqielle",
      "targetAbi": "10.11.0.0",
      "timestamp": "2026-07-15T00:00:00Z",
      "version": "${pluginVersion}",
      "status": 0,
      "autoUpdate": false,
      "assemblies": []
    }
  '';
  jellyfinOidcPlugin = pkgs.buildDotnetModule {
    pname = "jellyfin-plugin-oidc";
    version = pluginVersion;

    src = pkgs.fetchFromGitHub {
      owner = "Ezeqielle";
      repo = "jellyfin-plugin-oidc";
      rev = "0f037d99bf5849cceac1ecf7080b7a83f3b2cb64";
      hash = "sha256-4oRiD30Imm5MmYjz7dBoPQyooTvl5jMSEDuhpGaEX5Q=";
    };

    patches = [ ./patches/oidc-hardening.patch ];

    postPatch = ''
      cp -R ${./plugin-tests} Jellyfin.Plugin.OIDC.Tests
      chmod -R u+w Jellyfin.Plugin.OIDC.Tests
    '';

    projectFile = "Jellyfin.Plugin.OIDC/Jellyfin.Plugin.OIDC.csproj";
    testProjectFile = "Jellyfin.Plugin.OIDC.Tests/Jellyfin.Plugin.OIDC.Tests.csproj";
    nugetDeps = ./nuget-deps.json;
    dotnet-sdk = pkgs.dotnetCorePackages.sdk_9_0;
    dotnet-runtime = pkgs.dotnetCorePackages.aspnetcore_9_0;
    runtimeId = pkgs.dotnetCorePackages.systemToDotnetRid pkgs.stdenv.hostPlatform.system;
    doCheck = true;

    executables = [ ];
    postInstall = ''
      install -m 0444 ${localManifest} "$out/lib/jellyfin-plugin-oidc/meta.json"
    '';

    meta = {
      description = "Hardened OIDC and Quick Connect authentication plugin for Jellyfin";
      homepage = "https://github.com/Ezeqielle/jellyfin-plugin-oidc";
      license = lib.licenses.gpl3Only;
      platforms = lib.platforms.linux;
    };
  };
in
{
  # The runtime facet consumes this package without adding it system-wide.
  _module.args = { inherit jellyfinOidcPlugin; };
}
