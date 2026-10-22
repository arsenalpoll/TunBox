# Profile rule-provider merge fix (2026-10-22)

## Failure and cause

With ad blocking enabled and the local HyperAD asset present, the generated overlay
contains both the `hyper-adrules` provider and its `RULE-SET` reference. The profile
merger previously replaced all overlay providers with the subscription's providers
but retained overlay rules. A subscription without that provider therefore produced
`rule set [hyper-adrules] not found`, and the core could not start. Missing heartbeat
and unreachable API diagnostics were consequences of this configuration error.

## Change

- Merge overlay and profile rule-provider entries into one top-level mapping.
- Preserve overlay entries on name collisions, consistent with the generator's
  priority for app-owned HyperAD and custom `rs-*` providers.
- Deduplicate complete blocks and retain nested payload/header indentation.
- Preserve the existing file-readiness and enablement decisions. This fix adds no
  downloads, reconnect timers, or background polling.

## Validation

`scripts/verify-flclash-profile.mjs` regenerates its harness from current production
source on every run. The regression reproduced 11 failed assertions before the fix.
After the fix, 68 assertions pass, including 16 real runtime-builder combinations
(tunnel/test, profile/no profile, local file present/absent, ads enabled/disabled).
Only the platform DNS boundary is stubbed for those builder checks.

The 16 selected regression groups covering ad rules, routing, configuration,
foreground session adoption, keepalive, power refresh, and build-profile hygiene
pass. A standalone mihomo CLI is unavailable on this machine, so the optional real
core `-t` check remains explicitly skipped. Phone acceptance is still required.

The corrected test package keeps versionName `0.5.3` and increases versionCode to
`518` for replacement installation. Previous power and session fixes are retained.
