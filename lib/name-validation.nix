{ lib }:

let
  validDnsLabel = label:
    builtins.isString label
    && builtins.stringLength label >= 1
    && builtins.stringLength label <= 63
    && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" label != null;
in
rec {
  inherit validDnsLabel;

  validDnsName = name:
    builtins.isString name
    && builtins.stringLength name <= 253
    && builtins.all validDnsLabel (lib.splitString "." name);

  validPublicDomain = name:
    builtins.isString name
    && lib.hasInfix "." name
    && builtins.stringLength name <= 253
    && builtins.all validDnsLabel (lib.splitString "." name);

  # Kanidm provision entries in this repository use local entry names rather
  # than SPNs. Validate the common person/group/member namespace before the
  # provisioner gets a chance to fail against a live identity server.
  validKanidmEntryName = name:
    builtins.isString name
    && builtins.stringLength name >= 1
    && builtins.stringLength name <= 64
    && builtins.match "[a-z][a-z0-9._-]*" name != null;

  validKanidmUser = validKanidmEntryName;
  validKanidmGroup = validKanidmEntryName;
}
