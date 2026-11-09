## X6886 GPU governor - standalone module

This folder is a self-contained Magisk module: **GPU-DVFS-X6886**. It ships the same
`gpufix.sh` as the main patch, but with the adaptive governor switched on by default,
so it can be installed (or removed) on its own, without the FOD/GSI patch and without
touching `/data/adb/fod` config used by the main module.

It is built by `.github/workflows/release.yml` and published as a second release asset,
`GPU-DVFS-X6886-<version>-<sha>.zip`. Nothing here is copied at flash time - the
top-level `gpufix.sh` is the single source of truth, and CI fails if the two drift apart.

### What it changes on the device

Only these kernel nodes, and only while `ENABLED=1`:

| Node | Role | Idle value | Busy value |
|---|---|---|---|
| `/sys/kernel/ged/hal/custom_boost_gpu_freq` | GED boost floor (ladder **index**) | index of `MIN_HZ` (44, 390 MHz) | index of `TOP_HZ` (1200 MHz) |
| `/sys/module/ged/parameters/gpu_cust_boost_freq` | same value in kHz | 390000 | 1200000 |
| `/sys/module/ged/parameters/boost_gpu_enable` | arms the boost path | 1 | 1 |

The ceiling (`gpu_cust_upbound_freq` 1600 MHz) and `gpu_dvfs_enable` are never touched,
so inside the window the GPU still scales by demand and still idles at 390 MHz.

The governor samples `/sys/kernel/ged/hal/gpu_utilization` every `INTERVAL` s, raises the
floor when load >= `LOAD_ON` %, and holds it for `HOLD_S` s. It drops back at
`TEMP_MAX` battery temperature and refuses to run without a readable OPP ladder.

### Install / configure

Flash the ZIP, reboot. Config lives in `/data/adb/gpufix/gpu.conf`.

```sh
M=/data/adb/modules/gpu_dvfs_x6886
su -c "sh $M/gpufix.sh preset max"    # fastest OPP always, whole system
su -c "sh $M/gpufix.sh preset boost"  # 390 idle -> 1200 busy (default)
su -c "sh $M/gpufix.sh preset stock"  # release the floor
sh $M/gpufix.sh status                # state, live load, floor asked for, plan
sh $M/gpufix.sh probe 20              # use the phone normally while it runs
su -c "sh $M/gpufix.sh revert"        # undo the nodes (a reboot does too)
```

| preset | floor | ceiling | note |
| --- | --- | --- | --- |
| `max` | top OPP (`TOP_HZ=0`, `MODE=floor`) | top OPP (`CEIL_HZ=0`) | floor == ceiling, GPU cannot idle down |
| `boost` | 1200 MHz while busy, 390 idle | unchanged | follows `gpu_utilization`, holds 20 s |
| `stock` | 390 MHz | unchanged | nothing raised |

If `/proc/gpufreqv2/*` is unreadable to the shell (some GSIs deny it even to root),
`preset max` still works: it writes index 0 (the driver's name for the fastest OPP) to
both nodes, and the thermal brake drops the floor to `TOP_INDEX` (default 44 = slowest
OPP) at `TEMP_MAX`. `preset boost` needs the ladder and will refuse rather than guess.

Above `TEMP_MAX` (43 C battery) the floor drops to `HOT_HZ` (default 0 = stock floor)
until the phone cools; set `HOT_HZ=900000` to stay fast-but-safe instead. The loop
re-reads the config every ~15 ticks, so edits apply without a restart.

Remove the module in Magisk to stop it; `uninstall.sh` also restores the nodes.

### Known limits

* The vendor power HAL is free to rewrite `custom_boost_gpu_freq`; if that happens the
  governor simply sets it back on the next tick (that is what the loop is for).
* Where `/proc/gpufreqv2/*` is denied, `gpu_cust_boost_freq` / `gpu_cust_upbound_freq`
  are left holding their old kHz values while the enforced hal indices are 0. GED obeys
  the index, so this only affects the *reported* numbers, never the clock.
* This is still a *floor*: if the GPU never leaves 390 MHz even with the floor raised,
  the cap is elsewhere (firmware `[PPM Ceiling]`, thermal policy) and no write to these
  nodes will help. `gpufix.sh verify` is the honest test.
* Untested on hardware. The OPP index resolution is unit-tested on the host
  (`.github/tests/test_fixes.py`, `GpuHelperTests`).
