# Waiting for word selection in tests

[CI at 45c8f7f](https://github.com/HelgeSverre/terminal/actions/runs/42684436222)
failed with `selection made no progress`. The test counted 100,000 owner turns
while word segmentation ran on another queue. That count cannot bound how soon
the worker gets CPU time. CI did not name its exact word action.

A controlled scratch fixture paused the real word queue and ran the unchanged
old polling loop: [red.log](red.log) records the same failure. This is a
fault-injected reproduction, not an unmodified 45c8f7f binary. Releasing the
worker permits completion. The permanent regression keeps selection pending for
100,000 advances while the worker is paused, then releases it and verifies the
exact Unicode word across a soft wrap.

The test completion helper now waits for submitted word jobs using a semaphore
marker with a five-second timeout. It retains the owner-work turn bound and
accounts for separate first/end word jobs. Production Session scheduling and
word segmentation are unchanged. The [optimized full selection suite](green.log)
passes locally, including copy limits and cancellation.

```shell
just terminal-selection
```
