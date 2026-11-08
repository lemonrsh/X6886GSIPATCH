# X6886GSIPATCH
A magisk module FOD SOFOD double tap wake performance and many fixes on aosp gsi running on x6886

## v11.2.2 reliability fixes

- HBM watchdog timeouts are token-gated and cancelled/reaped before a newer
  fingerprint glow, so an old timer cannot turn off a newer HBM session.
  The existing `MAX_S` timeout and battery-temperature cutoff are unchanged.
- `fod_service.sh` and `sofod_touch.sh` use single-instance guards. Stale or
  unrelated PID files no longer block startup. Reboot after an in-place update so
  any pre-guard helper from the old install stops.
- Background dexopt can run during AOD/Dozing as well as Asleep, still only while
  charging or at >= 40% battery. Failed attempts retry instead of marking the
  module version complete.
- Host-side regression tests and bash/dash syntax checks run on PRs/main and
  before release. These are not a substitute for on-device FOD/AOD testing.
