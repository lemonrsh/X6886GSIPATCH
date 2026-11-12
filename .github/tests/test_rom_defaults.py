"""Offline regression checks for the screenshot-default bridge.

These validate the DEX payload and strict profile/ownership design; Android/provider
behavior still requires a supported ROM/device and is not claimed by these tests.
"""
import pathlib
import re
import struct
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RomDefaultsTests(unittest.TestCase):
    def test_profile_is_literal_and_screenshot_switch_states_are_complete(self):
        rows = {}
        for line in (ROOT / "phh-defaults.conf").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("|")
            self.assertEqual(len(fields), 5, line)
            kind, key, value, prop, propvalue = fields
            self.assertRegex(key, r"^(key_misc_[a-z0-9_]+|key_huawei_headset_fix)$")
            self.assertNotIn(key, rows)
            rows[key] = (kind, value, prop, propvalue)
        expected_on = {
            "key_misc_disable_audio_effects", "key_misc_disable_fast_audio",
            "key_misc_mediatek_touch_hint_rotate", "key_misc_mediatek_ged_kpi",
            "key_misc_disable_sf_gl_backpressure", "key_misc_disable_sf_hwc_backpressure",
            "key_misc_sf_disable_backpressure", "key_misc_sf_auto_latch_unsignaled",
            "key_misc_disable_voice_call_in", "key_misc_patch_smsc", "key_misc_securize",
            "key_misc_activity_anim_perf_override",
        }
        expected_off = {
            "key_huawei_headset_fix", "key_misc_headset_devinput", "key_misc_lmk_tweaks",
            "key_misc_dynamic_fps", "key_misc_no_hwcomposer", "key_misc_aod",
            "key_misc_disable_display_doze_suspend", "key_misc_sf_latch_unsignaled",
            "key_misc_force_navbar_off", "key_misc_low_gamma_brightness",
            "key_misc_linear_brightness", "key_misc_disable_buttons_backlight",
            "key_misc_backlight_scale", "key_misc_disable_le_apcfe",
            "key_misc_allow_binder_thread_on_incoming_calls", "key_misc_force_display_5g",
            "key_misc_restart_ril", "key_misc_dt2w", "key_misc_disable_sae_upgrade",
            "key_misc_force_sw_codecs", "key_misc_treat_virtual_sensors_as_real",
        }
        for key in expected_on:
            self.assertIn(key, rows)
            self.assertEqual(rows[key][1], "true", key)
        for key in expected_off:
            self.assertIn(key, rows)
            self.assertEqual(rows[key][1], "false", key)
        self.assertEqual(rows["key_misc_force_sw_codecs"][2:],
                         ("persist.sys.phh.force_sw_codecs", "false"))
        self.assertEqual(rows["key_misc_sf_latch_unsignaled"][2:],
                         ("persist.sys.phh.sf_latch_unsignaled", "0"))
        self.assertEqual(rows["key_misc_sf_auto_latch_unsignaled"][2:],
                         ("persist.sys.phh.sf_auto_latch_unsignaled", "1"))
        self.assertEqual(rows["key_misc_sb_padding_start"][1], "1")
        self.assertEqual(rows["key_misc_sb_padding_end"][1], "1")

    def test_dex_is_standard_payload_and_has_entry_class(self):
        dex = (ROOT / "rom-defaults.dex").read_bytes()
        self.assertTrue(dex.startswith(b"dex\n"))
        self.assertGreaterEqual(len(dex), 112)
        self.assertEqual(struct.unpack_from("<I", dex, 32)[0], len(dex))
        self.assertEqual(struct.unpack_from("<I", dex, 36)[0], 112)
        strings_off = struct.unpack_from("<I", dex, 60)[0]
        count = struct.unpack_from("<I", dex, 56)[0]
        strings = set()
        for i in range(count):
            off = struct.unpack_from("<I", dex, strings_off + 4*i)[0]
            while dex[off] & 128:
                off += 1
            off += 1
            end = dex.index(0, off)
            strings.add(dex[off:end].decode("utf-8", "replace"))
        self.assertIn("LX6886RomDefaults;", strings)
        self.assertIn("lock_screen_lock_after_timeout", strings)
        self.assertIn("pref.0.", strings)

    def test_owner_and_reversible_safety_guards_are_explicit(self):
        java = (ROOT / ".github/android/X6886RomDefaults.java").read_text()
        helper = (ROOT / "rom_defaults_lib.sh").read_text()
        self.assertIn('static final int USER = 0', java)
        self.assertIn("refreshStoredPinLength", java)
        self.assertIn("getCredentialTypeForUser", java)
        self.assertIn('"lineagesettings"', java)
        self.assertIn("state.needsRestore(id, t)", java)
        self.assertIn("ROM_PHH_STOPPED", helper)
        self.assertIn(".ui_stopping", java)
        self.assertNotIn("settings put", java)
        self.assertNotIn("key_misc_", helper)

    def test_post_fs_and_uninstall_are_wired_without_blocking_refresh(self):
        post = (ROOT / "post-fs-data.sh").read_text()
        service = (ROOT / "service.sh").read_text()
        uninstall = (ROOT / "uninstall.sh").read_text()
        self.assertIn("SF_LATCH_UNSIGNALED=0", post)
        self.assertIn("SF_AUTO_LATCH_UNSIGNALED=1", post)
        self.assertIn('rom_defaults.sh" ] && ( sh', service)
        self.assertIn('rom_defaults_restore', uninstall)
        self.assertIn('rom-defaults.dex', uninstall)


if __name__ == "__main__":
    unittest.main()
