# X6886GSIPATCH
A magisk module FOD SOFOD performance and many fixes on aosp gsi running on x6886

## v14.4.1 hotfix: FOD staying at 144 Hz

The device report confirmed a valid pair (**120 Hz = mode 0**, **144 Hz = mode 1**),
but no running refresh controller after its HAL-restart log entry. **Flash the new
ZIP in Magisk and reboot**; 0.4× animations and the existing DRAM/FOD safety limits
are retained.

- Both boot hooks now start one supervisor, which restarts a controller that exits
  and records its exit status/stderr. Disabling or uninstalling the module stops it.
- HAL restarts invalidate fingerprint session state without killing the logcat
  listener. Session epochs reject late events from an old reader.
- An empty SurfaceFlinger reply is **not automatically a failure or success**.
  Android's service utility can report an empty reply even when it did not expose
  the transaction status. The controller now checks the **actual active mode ID,
  physical Hz and render Hz** before acknowledging a FOD request, including each
  new HBM/SOFOD token. It cannot claim 120 Hz while the observed display is 144 Hz.
- The physical mode request is sent first; matching framework votes are updated
  immediately rather than waiting for the previous target's retry timer.

For a copy/paste report, no archive upload is required:

```sh
su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh refresh'
```

The report includes controller/supervisor liveness, the last verified/observed
rates, the raw mode-call reply and current SurfaceFlinger modes. Test on-device
FOD again after the reboot; host mocks cannot prove panel latency or biometric
reliability.

## v14.4: 0.4× animations, 144 Hz normal / 120 Hz fingerprint

Flash the release ZIP in Magisk and **reboot**. No commands or volume-key choices
are needed, including when upgrading from the old always-120-Hz release.

- **0.4× Android animations:** window, transition and animator-duration scales are
  set globally after boot and reconciled every 60 seconds. This covers framework
  animations for all users; an app's custom animation engine may ignore Android's
  scales.
- **144 Hz normally, 120 Hz for FOD:** the bundled bridge's authentication,
  enrolment and interaction/UI-ready events switch to 120 Hz; cancellation,
  session close and successful authentication/enrolment restore 144 Hz after any
  held finger/HBM/SOFOD request has ended. Failed recognition keeps the current
  fingerprint session at 120 Hz for the next attempt.
- HBM and screen-off touch replay request 120 Hz **before** enabling the glow or
  replaying input. A token-specific acknowledgement prevents a previous press's
  120-Hz result being reused. The wait is bounded to about 300 ms and fails open
  if the controller is unavailable, so it cannot block fingerprint capture.
- One supervised controller serialises all mode changes and matching min/peak framework
  settings, including early boot, foreground-user changes and SurfaceFlinger
  restarts. Shared FOD leases are checked every 50 ms; the press property is a
  100-ms fallback. These are software check intervals, not guaranteed panel
  transition times. Slow reconciliation defaults to 120 seconds.
- Mode IDs are discovered fresh, never guessed or reused from a previous boot.
  A same-resolution, same-HWC-group 144/120 pair is used to avoid disruptive
  modesets (older dumps without group metadata use a same-resolution pair).
  Without a compatible 144-Hz mode it stays at 120 Hz; without a 120-Hz mode it
  leaves Android's display policy alone. Unsupported SurfaceFlinger pins fall
  back to framework votes, with diagnostic logging rather than toasts/dialogs.
- Original animation and per-user refresh settings are saved once and restored
  on uninstall if they still match this module's last write. If Magisk removes
  the module before Android's settings provider starts, a module-owned one-shot
  `service.d/x6886_restore_settings.sh` finishes restoration after boot and removes
  itself. The removal reboot also clears the SurfaceFlinger pin. If upgrading from
  an older module that already pinned 120 Hz, that existing value is the saved
  original; reset Smooth Display manually if you want ROM defaults instead.

**Limits:** the panel/ROM must expose 144 Hz; this cannot make an FPS-capped app
render at 144 FPS, bypass thermal/display-driver limits, or guarantee zero flicker
or biometric errors on every GSI. Host regression tests are not on-device
validation. Test lockscreen unlock, app biometric prompts, enrolment and screen-off
FOD after flashing; keep the previous ZIP for rollback.

Config: `/data/adb/fod/refresh.conf` (`RECONCILE_S`, `SETTINGS_RATE`). Diagnostics:
`su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh'`.
Lost bridge streams/HAL restarts clear session state, FOD helper leases expire
within 8 seconds, and silent bridge sessions expire after 5 minutes without an
event. The property/next touch can still request 120 Hz after that safety timeout.

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
- Host-side regression tests and bash/dash/mksh/ash checks run on PRs/main and
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
