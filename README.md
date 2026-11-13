# X6886GSIPATCH
A magisk module FOD SOFOD performance and many fixes on aosp gsi running on x6886

## Level 2 v5: volume-key refresh mode selector and module status

**Flash the new ZIP in Magisk and reboot once.** Version code: **142**. The module ID
is unchanged, so this updates the existing installation. After installation, open the
module card in Magisk and tap **Action**:

- **Volume Up:** 144 Hz normally, with automatic switching to 120 Hz for fingerprint
  authentication/enrolment, screen-off FOD, sleep and wake protection.
- **Volume Down:** fixed 120 Hz everywhere; the controller continues to verify and
  repair the physical mode and Android min/peak refresh settings.
- **Power:** cancel without changing the selection (where the input driver exposes it).

The selection is saved in `/data/adb/fod/refresh_mode`, survives module upgrades and
is applied live without rebooting. Auto-switch remains the default for existing installs.
The Action output shows whether the refresh supervisor/controller processes are running,
the selected policy and the last physical/render-rate observation. **WORKING** means
both controller processes are alive; it is not a guarantee that every ROM/panel accepted
the requested rate. Check the last observation for actual verification.

The panel/ROM must expose a compatible 120 Hz mode. This cannot bypass display-driver
or thermal limits, or make an FPS-capped app render at 120/144 FPS. Test FOD and both
policies on-device; keep the previous release ZIP for rollback.

## Previous: Level 2 v4 — fast 144 Hz ↔ 120 Hz switching and one-touch screen-off FOD

**Flash the new ZIP in Magisk and reboot.** Version code: **141**. Same module ID, so
it updates the existing installation.

- **Framework votes no longer block switching.** Android's `settings` command starts a
  Java process for every call. The controller used to run up to four of them *before*
  confirming 120 Hz. Now they run in one background worker after the pin and ACK, so
  the FOD ACK, finger lift and the return to 144 Hz are never queued behind them.
- **Instant controller wake-up.** FOD helpers and the fingerprint/power log watcher
  wake the controller's 50 ms sleep with `SIGUSR1`. Helpers signal only the exact
  PID + start time the controller published, so a stale or reused PID is never
  signalled.
- **No redundant re-pin.** If 120 Hz is already verified, a new FOD hold is checked
  again right away without another Binder call. A mismatch still re-pins and repairs
  the votes. The panel state is now read on every loop (builtin read, no fork).
- **Screen-off FOD in one touch.** `sofod_touch` asks for 120 Hz before the panel
  wakes and takes a fresh hold once it is on. Its ACK wait runs during the 80 ms
  SystemUI delay instead of after it. HBM reuses that live post-wake ACK instead of
  waiting a second time. Coordinate parsing and logging no longer fork before the
  synthetic touch.
- **Safety is unchanged.** Every wait still fails open and is bounded by uptime
  (300 ms ACK, 1.2 s panel). The 150 ms upshift settle, HBM temperature/timeout limits
  and all other tuning stay the same.

**Validation:** host regression tests on bash, dash, mksh and BusyBox ash. With a
simulated 1.5 s `settings` CLI, the 120 Hz ACK went from about 2.1 s to 0.06 s and
the return to 144 Hz from about 1.2 s to 0.23 s. These are host numbers, not phone
measurements, so test on the device.

## Previous: Level 2 v3 — screenshot-matched PHH and Android defaults

### Full-charge screen-on-time baseline (experimental)

`sot_reset.sh` waits for battery capacity `100` and status `Full`, then requests one
`dumpsys batterystats --reset` per full-charge event. It re-arms after the device
leaves Full and does not loop-reset while the phone remains charged. This resets
Android BatteryStats history (not just the SOT counter), so other battery-usage
history may also clear. It is enabled by default; set `SOT_RESET=0` in
`/data/adb/fod/sot_reset.conf` to opt out. ROMs differ in how Settings displays SOT,
so this needs on-device validation and cannot guarantee every GSI's display behavior.

**Flash the new ZIP in Magisk and reboot.** Version code: **140**. The module
ID remains unchanged for an in-place update. A finite boot task applies the pictured
PHH preferences after the owner unlocks; refresh/FOD controllers start independently.
It sets status-bar start/end padding to **1**, selects **Immediately** for lock-after-
timeout, and matches supported PHH/power-menu switches. PIN auto-confirm is attempted
only for an existing eligible PIN and only through Android's LockPatternUtils plus
the Settings-style PIN-length refresh. It never reads or changes a credential. Unknown
list values remain untouched; missing ROM features are skipped. Original values and
module ownership are recorded for uninstall, and the previous ZIP should be kept for
rollback. This change has host tests only—no phone/ROM validation is claimed.

PHH preferences are changed only while the PHH app process is stopped, then the
app is resumed; unsupported keys are detected from the installed APK's DEX. The
module does not edit preferences through shell/XML, use invented Settings provider
keys, or invoke old Securize behavior that can remove root.

## Previous: Level 2 v2 — wake/boot-safe 144 Hz ↔ 120 Hz recovery

**Flash the new ZIP in Magisk and reboot.** Version code: **139**. The module ID
is unchanged, so this updates the existing module rather than adding a second
refresh controller.

This fixes two software recovery gaps behind intermittent FOD-at-144 reports:
a cached “120 Hz applied” result could survive a wake-time display override, and
three unsuccessful pin requests could stop further requests until the slow rescan.

- **Pre-arm 120 Hz during early boot and sleep/AOD.** The existing
  `post-fs-data.sh` supervisor starts before `sys.boot_completed`; as soon as
  SurfaceFlinger exposes supported modes, it requests 120 Hz. A full power-off or
  reboot starts discovery again; no mode IDs or old acknowledgements are reused.
  Nothing can run while the phone is powered off, or before Android/Magisk and
  SurfaceFlinger exist. Bootloader/vendor firmware is not changed.
- **Wake invalidates the cached display result, even if the target is still
  120 Hz.** Follow early Android power and bundled bridge sleep/wake logs, with
  builtin panel reads as a fallback. A suspend-like loop gap also triggers
  recovery; a bounded framework power snapshot reconciles missed edges every
  10 seconds. Sleep keeps 120 Hz pre-armed. Wake has a **1-second 120 Hz guard**
  while HAL/SystemUI registers FOD; an active prompt/press/HBM/SOFOD keeps it there.
- **144 Hz returns when FOD is inactive.** A short **150 ms upshift settle**
  coalesces release/cancel callbacks to avoid bouncing 120 → 144 → 120 between
  touches. Downshifts have no added debounce. Existing 50 ms lease / 100 ms press
  checks remain; these are software intervals, not panel-latency guarantees.
- **Recover instead of giving up.** Initial pin retries are fast, with continued
  bounded backoff up to 5 seconds for persistent failures. Both rates are observed
  periodically (120 Hz every second, normal 144 Hz every 5 seconds); a mismatch
  invalidates the ACK and repairs physical mode and live framework votes. Mode
  tables are rediscovered after failures and SF process identity changes.
- **Refresh settings are audited, not just cached.** Check live min/peak votes
  every 5 seconds at 120 Hz / 15 seconds at 144 Hz, and immediately on target/wake
  changes or a verified-mode override. Original values and uninstall restoration
  are retained. Binder CLI calls use a 1-second timeout when supported; display
  and fingerprint dumps use their native timeouts.
- **Recover missed fingerprint events safely.** Reseed current operations after
  wake/boot/restarts and periodically. Unknown/failed snapshots do not mean “no
  prompt”; a snapshot cannot overwrite a newer bridge event or a recent cancel.
  The bridge's earliest screen-off sensor press now requests 120 Hz before replay.

Only an **observed matching mode ID and physical/render rate** can acknowledge a
fresh HBM/SOFOD token. The existing roughly 300 ms fail-open helper wait, 8-second
helper leases, HBM temperature/timeout safety, HAL patches, 0.4× animations,
4266/1866 MHz DRAM policy and other performance/download tuning are retained.

**Validation:** 108 host regressions across bash, dash, mksh and BusyBox ash,
including repeated wake/policy overrides, missing events, stalled Binder CLI,
more than three failed requests, changed mode tables and simulated cold boots.
These are **not on-device validation**. The panel/ROM must expose a compatible
144/120 pair; driver latency, thermal restrictions, zero flicker and universal
biometric reliability cannot be guaranteed. Test repeated screen-off FOD, normal
wake, app prompts, enrolment and a full power-off/reboot on the phone. Keep the
previous release ZIP for rollback.

Plain-text diagnostics (includes screen/trigger/retry state):

```sh
su -c 'sh /data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh/diag.sh refresh'
```

## Previous: Level 2 v1 — module CPU overhead and stability only

That release optimized **the module's own background work** without changing
phone tuning or removing features. Its optimizations are retained. **Flash the ZIP in Magisk and reboot.** The
version code is **138**. The module ID deliberately remains
`X6886_GSI_PATCH_level_1_by_lemonrsh` so this is an in-place update, not a second
module fighting the old one.

- Native, flushed FOD filtering also works when Android's grep lacks
  `--line-buffered`: prefer Magisk/PATH BusyBox awk, then interactive awk.
  Coordinate/SYN traffic stays out of the shell on supported toolsets; unsupported
  toolsets and `FAST_FILTER=0` retain the original fallback. Input buffering is
  explicitly accounted for, not just output flushing.
- Builtin file reads replace repeated `cat` processes for touch-device discovery,
  panel state, battery temperature and HBM tokens. Bridge-event parsing no longer
  forks a subshell for each log line.
- Unchanged runtime snapshots and settings ownership markers are not rewritten.
  Live settings are still checked/reconciled; actual display observations and
  changed state still update diagnostics. `.refresh_runtime` records the last
  state/observation, **not a per-second heartbeat**.
- HAL/SF watchdogs check cached PID/start times with builtin reads and only scan
  for replacements when needed. PID reuse and unavailable `/proc` identities are
  handled; the existing 15/30-second watchdog cadence is unchanged.
- The refresh controller honours live disable/remove flags during its existing
  periodic check, even when the supervisor is waiting for it to exit.

**Unchanged:** 0.4× animation scales; 144 Hz normal / 120 Hz fingerprint; all FOD
lease/ACK checks, waits and replay timings; 4266/1866 MHz screen-aware DRAM lock;
HBM thermal/timeout protection; HAL patches; CPU/IO/download tuning and settings
restoration. CPU governor policy stays with Android/vendor defaults; the optional performance-governor request is disabled by default and no longer polls sysfs.

**Validation:** 86 host regressions across bash, dash, Android-source mksh and
BusyBox ash, including open-pipe input-latency checks and counted redundant
writes/scans. No phone CPU profile was supplied, so there is **no measured CPU
reduction percentage or hardware guarantee**. Test idle/scrolling and FOD after
reboot; keep the previous release ZIP for rollback. Plain-text diagnostics remain
available via `diag.sh` / `diag.sh refresh`; no archive upload is required.

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

- Release titles use the module's `name` from `module.prop`, including the
  **Level 2 v1** branding. Version and commit details remain in the release notes.
- Release tags combine the `module.prop` version and commit SHA, for example
  `vLevel-2-v1-<short-sha>` (spaces in the version are replaced with hyphens), so
  commits with the same module version get separate releases.
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
