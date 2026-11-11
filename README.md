# X6886GSIPATCH
A magisk module FOD SOFOD performance and many fixes on aosp gsi running on x6886

## v14.3: DRAM lock (screen on = max, screen off = half)

`dramlock.sh` locks the MediaTek DVFSRC DRAM clock (`/sys/class/devfreq/mtk-dvfsrc-devfreq`):

| Screen | DRAM | Notes |
| --- | --- | --- |
| On | 4266 MHz (top step) | applied as soon as the wake-up starts |
| Off / AOD | 1866 MHz | "half" = largest step at or below 4266 / 2 |

- Switches instantly and seamlessly (1866 -> 4266 MHz directly, never through the lowest step).
  Triggers: PowerManagerService's `Waking up from` / `Going to sleep` log lines (v14.3), a no-fork panel check every 0.5 s
  (dpms/backlight, confirmed by `dumpsys power` so AOD stays at half), and a 60 s reconcile
  that re-applies the lock if the power HAL or thermal code undid it.
- v14.2 fixes v14.1 staying at 1866 MHz with the screen on when the screen event was missed.
- Config: `/data/adb/fod/dram.conf` (`DRAM_LOCK`, `ON_FREQ`, `OFF_FREQ`, `RECONCILE_S`).
  To apply changes without a reboot:
  `su -c sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/dramlock.sh reload`.
- Status: `su -c sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/dramlock.sh status`.
- `DRAM_LOCK=0` followed by `reload` gives control back to the stock governor.
- Holding DRAM at max while the screen is on uses more battery and makes the phone warmer.
- The installer renames an old manual `/data/adb/service.d/lock_dram.sh` to
  `lock_dram.sh.disabled_by_x6886` so it can't fight the screen-off step.

## v14: GPU governor (`gpufix`) removed

- Removed `gpufix.sh` and the bundled `gpumod/` standalone GPU module so GPU DVFS
  control can be developed and released as a separate module project.
- Removed the GPU installer volume-key prompt, `gpu.conf` creation, `service.sh`
  launch, `diag.sh` GPU entries, and the second ZIP build in `.github/workflows/release.yml`.
- On in-place upgrades from v11.3–v13, `customize.sh` stops any legacy main-module
  `gpufix` loop and cleans up `/data/adb/fod/gpu.*` / `.gpufix.*` without touching
  `/data/adb/gpufix` state from a separate GPU module.

## v11.2.2 reliability fixes

- HBM watchdog timeouts are token-gated and cancelled/reaped before a newer
  fingerprint glow starts, so an old timer cannot turn off a newer HBM session.
  The existing `MAX_S` timeout and battery-temperature cutoff are unchanged.
- `fod_service.sh` and `sofod_touch.sh` use single-instance guards. Stale or
  unrelated PID files no longer block startup. Reboot after an in-place update so
  any pre-guard helper from the old install stops.
- Background dexopt can run during AOD/Dozing as well as Asleep, still only while
  charging or at >= 40% battery. Failed attempts retry instead of marking the
  module version complete.
- Host-side regression tests and bash/dash syntax checks run on PRs/main and
  before release. These are not a substitute for on-device FOD/AOD testing.

## Automatic Magisk releases

The [release workflow](.github/workflows/release.yml) runs on every push to `main`.
It checks the module layout, packages the tracked module files into a flashable
ZIP (with `module.prop` and `META-INF` at the ZIP root), and publishes a GitHub
Release. GitHub configuration and untracked build artifacts are excluded.

- Release titles are `x6886 aosp gsi patch`, independently of the module's
  internal name. The version and commit details remain in the release notes.
- Release tags combine the `module.prop` version and commit SHA, for example
  `v11.2.1-39139a3`, so commits with the same module version get separate releases.
- Several commits in one push produce one release for the pushed HEAD commit.
- Rerunning the workflow for the same commit replaces that release's ZIP instead
  of creating a duplicate.
- After the workflow is on `main`, you can also build manually using
  **Actions → Release Magisk module → Run workflow**.
- You do not need to bump the version just to generate a new CI release. For a
  module upgrade that Magisk/update channels recognize, still increment both
  `version` and `versionCode` in `module.prop`.

Download the release's `.zip` asset, choose **Install from storage** in Magisk,
and reboot. Do not extract the ZIP or use GitHub's automatic source-code archives.
The workflow must be merged into `main` before automatic releases can start.
If your repository settings restrict the workflow token, allow read/write
repository permissions under **Settings → Actions → General → Workflow permissions**.
