{ lib }:

{
  validRemoteName = name:
    builtins.isString name
    && builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;

  validDestination = remoteName: destination:
    builtins.isString remoteName
    && builtins.isString destination
    && (
      let
        prefix = "${remoteName}:";
        path = lib.removePrefix prefix destination;
        segments = lib.filter (segment: segment != "") (lib.splitString "/" path);
      in
      lib.hasPrefix prefix destination
      && path != ""
      && !(lib.hasPrefix "/" path)
      && lib.all (segment: segment != "." && segment != "..") segments
    );
}
