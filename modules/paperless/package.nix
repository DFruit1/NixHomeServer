{ lib, pkgs, ... }:

let
  patchedPaperlessFetchFromGitHub =
    args:
    pkgs.runCommand "${args.repo}-${lib.replaceStrings ["/"] ["-"] args.tag}-patched"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.perl
        ];
        src = pkgs.fetchFromGitHub args;
      }
      ''
        cp -a "$src" "$out"
        chmod -R +w "$out"
        jq 'del(.packageManager)' "$out/src-ui/package.json" > "$out/src-ui/package.json.tmp"
        mv "$out/src-ui/package.json.tmp" "$out/src-ui/package.json"
        substituteInPlace "$out/src/documents/templates/account/signup.html" \
          --replace-fail '{% if not FIRST_INSTALL %}' '{% if True %}'
        perl -0pi -e 's/user: User = super\(\)\.save_user\(request, sociallogin, form\)/user = sociallogin.user\n        if (\n            User.objects.exclude(username__in=["consumer", "AnonymousUser"]).count()\n            == 0\n            and Document.global_objects.count() == 0\n        ):\n            logger.debug(f"Creating initial social superuser `{user}`")\n            user.is_superuser = True\n            user.is_staff = True\n        user: User = super().save_user(request, sociallogin, form)/' \
          "$out/src/paperless/adapter.py"
      '';

  paperlessPackage = pkgs.callPackage (pkgs.path + "/pkgs/by-name/pa/paperless-ngx/package.nix") {
    fetchFromGitHub = patchedPaperlessFetchFromGitHub;
    nodejs_20 = pkgs.nodejs_22;
  };
in
{
  services.paperless.package = paperlessPackage;
}
