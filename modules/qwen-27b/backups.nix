{ ... }:

{
  # The GGUF artifacts live on the data pool under /mnt/data/qwen-27b/models,
  # which is not a Kopia snapshot root. They are reproducible, hash-verified
  # public downloads and are intentionally left out of backups; removing this
  # module does not delete them.
  #
  # The retired Qwen3.8-Flash-Next weights were moved to
  # /mnt/data/archive/qwen-flash-next rather than deleted. Nothing references
  # that directory; restore it only by hand if the old model is ever needed
  # again.
}
