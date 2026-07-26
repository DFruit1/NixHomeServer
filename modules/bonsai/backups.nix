{ ... }:

{
  # The persistent directory contains only reproducibly downloaded model
  # artifacts. Excluding it from Kopia avoids backing up roughly 7.8 GB that
  # can be restored from the pinned public repository and verified hashes.
}
