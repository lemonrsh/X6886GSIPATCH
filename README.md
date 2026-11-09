# X6886GSIPATCH
A magisk module FOD SOFOD performance and many fixes on aosp gsi running on x6886

## v12: one command, and the 1100 MHz cap is gone for real

**The actual cause** of "safer still shows 1100 MHz": on a build where `/proc/gpufreqv2` is
denied, the script could name a ladder *index* but not its *frequency*. So it wrote index 0
to `custom_upbound_gpu_freq` and left `gpu_cust_upbound_freq` at the stock `1100000`. GED
enforces the kHz parameter — the GPU stayed at 1100 MHz while every index looked perfect.

Fixed by knowing both ends of the ladder from the config (`TOP_HZ_KHZ=1600000`,
`BOTTOM_HZ_KHZ=390000`) and always publishing a real frequency alongside the index.

### If you already flashed something older

```sh
su -c "sh /data/adb/modules/gpu_dvfs_x6886/gpufix.sh reapply"
```

No arguments, no node editing. It repairs the config values older installers left behind
(`TEMP_MAX 430 -> 500`, `CEIL_HZ 1600000 -> 0`, `MIN_HZ 390000 -> 790000` for safer,
missing `SAFE_INDEX`), publishes the ceiling and the floor as **index + kHz**, and wakes
the running loop. Fresh flashes run it automatically, so a reflash is enough.

### Reading `status` honestly

`status` now prints the battery temperature against the limit, and shouts when a hal index
and its kHz parameter disagree:

```
temp:  38 C   limit=50 C (nothing throttled below it)
ceil:  hal index 0 means 1600000 kHz, but cust_upbound_freq reads 1100000.
       That stale parameter is what caps the GPU. Fix: 'reapply'.
```

## v11.10 MAX sleeps at 390 MHz with the screen off

`max` no longer sits at 1600 MHz with the screen dark. It now follows the screen:

| state | MAX | SAFER |
| --- | --- | --- |
| screen on | **1600 MHz** (floor = ceiling) | 790 MHz rest, 1600 on any GPU/CPU work |
| screen off | **390 MHz** | 390 MHz |
| 50 °C | 390 MHz until cool | 390 MHz until cool |

The switch happens on the next 1 s tick in both directions, so waking the phone is back at
1600 almost instantly. `status` previews it (`plan: ... screen-off -> level 44`).

## v11.9 Repair commands

```sh
su -c "sh $M/gpufix.sh ceil 0"      # publish the top OPP on GED's upper bound (repairs 1100 MHz)
su -c "sh $M/gpufix.sh ceil 1200000"  # or a fixed bound, when the ladder is readable
su -c "sh $M/gpufix.sh release"     # floor to the lowest OPP (390) - works without /proc
su -c "sh $M/gpufix.sh status"      # state, plan, ceiling, safer decision, loop pid
```

`ceil` writes the bound, reads it back and tells you the resulting hal index; on a build
where `/proc/gpufreqv2` is denied only `ceil 0` (the top OPP) can be set, and it says so.
`release` always means the **lowest** OPP, never the safer profile's 790 MHz rest floor.

## v11.8 SAFER now really reaches 1600: the ceiling is lifted too

**Bug (reported): "safer variant shows max 1100 MHz".** The floor asked for 1600 MHz but the
GED **upper bound** was left at the stock `gpu_cust_upbound_freq=1100000` (hal index 9), and
GED never runs above that bound. `safer` — like `boost` — only ever moved the floor, so the
GPU stopped at exactly 1100 MHz.

`safer` now publishes the ceiling as well (`CEIL_HZ=0` = the top OPP, the same value
`preset max` uses), and the running loop keeps it enforced. Existing safer installs are
healed on the next flash, and `status` now says it out loud when the ceiling is the thing
holding the GPU back:

```
! the ceiling is CAPPING the GPU at 1100000 kHz (hal index 9).
  The floor can ask for 1600 all it likes; GED will not go above this.
  Fix: 'gpufix.sh preset safer' (lifts both), or 'gpufix.sh ceil 0'.
```

If you are already on the broken build, one command fixes it without reflashing:

```sh
su -c "sh /data/adb/modules/gpu_dvfs_x6886/gpufix.sh preset safer"
su -c "sh /data/adb/modules/gpu_dvfs_x6886/gpufix.sh status"   # ceil: ... - the top OPP is allowed
```

### SAFER: 790 MHz rest, 1600 on any UI work, 390 asleep

`safer` now runs a **three-step** policy and it is driven by the CPU as well as the GPU, so
the whole UI benefits, not just games.

| state | floor | why |
| --- | --- | --- |
| anything at all is happening (GPU **or** CPU busy) | **1600 MHz** | the UI is composited on the CPU: scrolling, app switching, dialogs, video |
| idle, screen on | **790 MHz** | responsive rest floor instead of the old 390 |
| screen off | **390 MHz** | nothing on screen needs the GPU |
| battery ≥ 50 °C, or < 15 % unplugged | **390 MHz** | safety release |

It reaches 1600 within one 1 s sample (`LOAD_ON=25`, `CPU_ON=60`), holds `HOLD_S=6` after
the last busy sample, then settles back to 790. Both profiles keep the **same 50 °C thermal
limit** — nothing is throttled below it, and at 50 °C the floor drops all the way to 390 MHz
until the phone cools.

```sh
M=/data/adb/modules/gpu_dvfs_x6886       # or .../X6886_GSI_PATCH_level_1_by_lemonrsh
su -c "sh $M/gpufix.sh preset safer"     # recommended
su -c "sh $M/gpufix.sh preset max"       # pinned: floor = ceiling = 1600 MHz, always
su -c "sh $M/gpufix.sh preset stock"     # let go of everything
```

| | `safer` | `max` |
| --- | --- | --- |
| idle, screen on | 790 MHz | **1600 MHz** |
| GPU or CPU busy | 1600 MHz (within 1 s) | 1600 MHz |
| screen off | 390 MHz | **390 MHz** |
| at 50 °C | 390 MHz until cool | 390 MHz until cool |
| heat / drain | low | high while the screen is on |

The installer asks with the volume keys: **VOLUME UP = SAFER**, **VOLUME DOWN = MAX**, no
press = SAFER. `max` and `stock` reset `MIN_HZ`/`SLEEP_HZ` to 390, so switching profiles never
inherits the safer rest floor.

### Knobs

| config | default | meaning |
| --- | --- | --- |
| `MODE` | `safer` | `safer` \| `adaptive` \| `floor` \| `off` |
| `MIN_HZ` | `790000` | safer rest floor while in use |
| `SLEEP_HZ` | `390000` | floor for screen off / hot / low battery |
| `TOP_HZ` | `0` | busy floor; `0` = the fastest OPP (1600 MHz) |
| `CEIL_HZ` | `0` | GED upper bound published by safer/max; `0` = the top OPP. At the stock `1100000` the GPU cannot pass 1100 MHz |
| `CPU_ON` | `60` | CPU busy % that also raises the floor (raise it towards 100 for GPU-only) |
| `LOAD_ON` | `25` | GPU load % counted as busy (safer preset) |
| `HOLD_S` | `6` | how long the top OPP is kept after the last busy sample |
| `TEMP_MAX` | `500` | the **only** throttle point: 50 °C battery |
| `HOT_HZ` | `0` | floor at/above `TEMP_MAX`; `0` = `SLEEP_HZ` |
| `SCREEN_OFF_MIN` | `1` | safer: use `SLEEP_HZ` whenever the screen is off |
| `BAT_MIN` | `15` | safer: below this % (not charging) use `SLEEP_HZ` |
| `SAFE_INDEX` | auto | ladder index of `MIN_HZ` when `/proc/gpufreqv2` is unreadable |

`status` prints `idle=`, `busy=`, `sleep=`, `screen=`, `cpu_on=` and `charging=` while
`safer` is active, so the live decision is visible. Where `/proc/gpufreqv2` is denied,
`MIN_HZ` falls back to `SAFE_INDEX` (auto-filled to 43 = one step above the lowest OPP if
the ladder was never readable) and everything else still works.

## v11.5 GPU presets that also work on locked-down /proc

## v11.5 GPU presets that also work on locked-down /proc

On some GSI/vendor combinations `/proc/gpufreqv2/*` is denied to the shell even as root,
and GED's upper bound (`gpu_cust_upbound_freq`) can sit *below* the ladder top — both
were true on the device that motivated this release (`custom_upbound_gpu_freq` capped the
GPU at 1100000 kHz, so no floor could ever reach 1600).

`preset max` now handles both cases: with no readable ladder it writes **index 0** (the
driver's own name for the fastest OPP) to the floor *and* the ceiling nodes, and the
thermal brake keeps working by dropping to `TOP_INDEX` (default 44 = slowest OPP) at
`TEMP_MAX`. `status` prints the live upper bound and says outright when it is not the top
OPP. `revert` restores both ceiling nodes.

| config | default | meaning |
| --- | --- | --- |
| `CEIL_HZ` | `1600000` | GED upper bound to publish; `0` = fastest OPP |
| `TOP_INDEX` | `44` | slowest OPP, used only when the ladder is unreadable |
| `HOT_HZ` | `0` | floor while above `TEMP_MAX`; `0` = `MIN_HZ` |

## v11.4 GPU presets: max / boost / stock

One command sets the whole policy:

```sh
M=/data/adb/modules/gpu_dvfs_x6886       # or .../X6886_GSI_PATCH_level_1_by_lemonrsh
su -c "sh $M/gpufix.sh preset max"       # fastest OPP (1600 MHz) all the time, whole system
su -c "sh $M/gpufix.sh preset boost"     # 390 MHz idle -> 1200 MHz while busy (default)
su -c "sh $M/gpufix.sh preset stock"     # release the floor, stock behaviour
```

| preset | `MODE` | floor | behaviour |
| --- | --- | --- | --- |
| `max` | `floor` | fastest OPP (`TOP_HZ=0` -> 1600 MHz) | pinned at the top, every app and screen state |
| `boost` | `adaptive` | 1200 MHz while busy, 390 idle | follows `gpu_utilization`, holds 20 s |
| `stock` | `off` | 390 MHz | nothing is raised |

`preset` rewrites `/data/adb/fod/gpu.conf` (or `/data/adb/gpufix/gpu.conf` for the
standalone module) keeping your other keys and comments, and applies the floor
immediately when run as root. At or above `TEMP_MAX` (now 50 °C) the floor drops to
`HOT_HZ` (default 0 = stock floor) until the phone cools. Nothing below 50 °C throttles.

**`max` means pinned.** Floor == ceiling == 1600 MHz, so the GPU has no lower step to
fall back to. That is the "maximum always, whole system" behaviour, with the battery
drain and heat that come with it. `boost` gives most of the responsiveness for far less.

`gpufix.sh status` prints the state, the live load, the floor this module asked for and
what it would do next; `probe 20` samples frequency and load and tells you whether the
GPU actually moved.

### How the floor works

On this device the GPU is not locked — `gpu_dvfs_enable=1` and
`[GPU-LimitC] CeilingIndex: 0` — but GED's boost path is inert (`boost_gpu_enable=0`,
`gpu_cust_boost_freq=390000` = the slowest OPP), so in practice the clock sat at 390 MHz
unless GED itself saw sustained 3D work. The governor moves that path's target instead:
it resolves the requested frequency against the live OPP ladder and writes the ladder
**index** to `/sys/kernel/ged/hal/custom_boost_gpu_freq`, syncing
`gpu_cust_boost_freq` and `boost_gpu_enable=1`. The ceiling and `gpu_dvfs_enable` are
never written. The loop re-reads the node every tick, so a vendor power HAL that
rewrites it gets corrected; `revert` (or a reboot) restores the snapshot.

## v11.3 load-following GPU governor (opt-in)

On this device the GPU is not locked — `gpu_dvfs_enable=1` and
`[GPU-LimitC] CeilingIndex: 0` — but GED's boost path is inert
(`boost_gpu_enable=0`, `gpu_cust_boost_freq=390000` = the slowest OPP), so in practice
the clock sits at 390 MHz unless GED itself sees sustained 3D work.

`gpufix.sh` makes the floor follow load instead:

| `gpu_utilization` load | floor requested |
| --- | --- |
| below `LOAD_ON` (60 %) and `HOLD_S` (20 s) elapsed | `MIN_HZ` 390 MHz (stock) |
| at/above `LOAD_ON` | `TOP_HZ` 1200 MHz, held for `HOLD_S` after |
| battery ≥ `TEMP_MAX` (50 °C) | released to `MIN_HZ` |

Ceiling (1600 MHz) and `gpu_dvfs_enable` are never written, so the GPU still scales by
demand inside the window and still idles at 390 MHz.

```sh
M=/data/adb/modules/X6886_GSI_PATCH_level_1_by_lemonrsh
sh $M/gpufix.sh status          # state, live load, plan, verdict — writes nothing
sh $M/gpufix.sh probe 20        # use the phone normally while it runs
```

Enable it in the main patch by setting `ENABLED=1` in `/data/adb/fod/gpu.conf`
(`MODE=floor` for an always-raised floor, `MODE=off` to always release), or install the
standalone **GPU-DVFS-X6886** module from the same release — same script, own state in
`/data/adb/gpufix`, own uninstaller. Do not run both.

`gpufix.sh revert` or a reboot restores the stock nodes.

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
