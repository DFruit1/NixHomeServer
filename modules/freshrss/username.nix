let
  pattern = "([0-9A-Za-z]|[0-9A-Za-z_][0-9A-Za-z_.@-]{1,38})";
in
{
  inherit pattern;
  shellPattern = "^${pattern}$";
  valid = username:
    builtins.isString username
    && builtins.match pattern username != null;
}
