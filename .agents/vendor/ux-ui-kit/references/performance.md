# performance

On-demand reference adapted from the vendored MIT UI/UX Kit. Project policy
and frontend-design govern scope and completion.

Measure the reported delay or layout shift on a named workload/device before
optimizing. Use existing profiling tools. Inspect requests, redundant work,
media dimensions, and loading relevant to the symptom. Preserve Qwik's default
chunk strategy and shared cache-control helpers. Re-measure the same case.
Do not infer field Web Vitals from one local run or add unrequested benchmarks.
