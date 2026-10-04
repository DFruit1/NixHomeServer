{ ... }:

{
  # ntfy is stateless on first boot. The generated server.yml is the whole
  # configuration and the state directory is created by the unit itself, so no
  # bootstrap unit is needed and nothing here runs before ntfy is available.
}