# Measured optimization

Identify the user's cost and the quality that must remain: latency, repeated
work, throughput, storage, transfer volume, or desktop responsiveness. A request
for faster processing does not silently authorize lower-quality encoding,
weaker validation, more concurrency, spending, or changed build allocation.

Measure the reported case with the owning app's existing diagnostics and one
bounded workload. Record conditions such as input size, cold/warm caches,
elapsed time, CPU/RAM, or bytes transferred as relevant. Distinguish measured
results from estimates; do not introduce a benchmark suite unless it meets
AGENTS.md's test-creation policy or is explicitly requested.

Look first for duplicate scans/decodes/downloads, repeated queries or full-store
walks, unnecessary copies/hashing, and work that should be incremental. Keep
expensive maintenance off request paths and use the lowest useful cadence.
Reusing a validated artifact can help more than parallelizing its recreation.

When changes need resource controls, use the established owning service/helper
interfaces within current authority. Consider aggregate load across processes
and avoid new wrappers or global settings for a local symptom. Preserve reserved
buildMode/max-jobs decisions and use remote helpers only within authorized scope.

Re-measure the same case and verify that output quality and behavior remain
correct. Name the gain and its limits. Avoid an unrelated optimization sweep
after the reported problem is resolved.
