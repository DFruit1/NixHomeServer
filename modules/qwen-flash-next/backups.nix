{ ... }:

{
  # The ~94 GB of GGUF artifacts live on the data pool under
  # /mnt/data/qwen-flash-next/models, which is not a Kopia snapshot root. They
  # are reproducible, hash-verified public downloads and are intentionally left
  # out of backups; removing this module does not delete them.
}
