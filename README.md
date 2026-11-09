# X6886GSIPATCH
A magisk module FOD SOFOD performance and many fixes on aosp gsi running on x6886

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
