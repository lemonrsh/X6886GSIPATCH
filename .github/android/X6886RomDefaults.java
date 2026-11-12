/* X6886 screenshot defaults bridge. No Android SDK dependency at compile time.
 * Reflection is limited to named framework APIs; never loads PHH app code, edits
 * locksettings.db, reads a credential, or invents Settings-provider PHH keys.
 */
import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.Charset;
import java.util.*;
import java.util.zip.*;

public final class X6886RomDefaults {
    static final Charset UTF8 = Charset.forName("UTF-8");
    static final String PHH = "me.phh.treble.app";
    static final String PREFS = PHH + "_preferences";
    static final int USER = 0; // Screenshot profile is the owner, never work/guest profiles.

    interface Target {
        String get() throws Exception; // null is ABSENT, not the string "null"
        void put(String value) throws Exception;
    }

    /* Durable original / last-write ownership. Failed/in-flight writes retain a
     * pending value so a power loss between commit and ACK is still reversible. */
    static final class State {
        final File dir;
        State(File dir) { this.dir = dir; }
        File file(String id, String suffix) {
            if (!id.matches("[a-zA-Z0-9_.]+")) throw new IllegalArgumentException("bad state ID");
            return new File(dir, "rom." + id + "." + suffix);
        }
        static boolean same(String a, String b) { return a == null ? b == null : a.equals(b); }
        String read(File f) throws IOException {
            String s = new String(bytes(f, 16384), UTF8).trim();
            if (s.equals("-")) return null;
            try { return new String(Base64.getDecoder().decode(s), UTF8); }
            catch (IllegalArgumentException e) { throw new IOException("invalid saved value", e); }
        }
        void save(File f, String value) throws IOException {
            File tmp = new File(f.getPath() + ".tmp");
            FileOutputStream out = new FileOutputStream(tmp);
            try {
                tmp.setReadable(false, false); tmp.setWritable(false, false);
                tmp.setReadable(true, true); tmp.setWritable(true, true);
                String s = value == null ? "-" : Base64.getEncoder().encodeToString(value.getBytes(UTF8));
                out.write((s + "\n").getBytes(UTF8)); out.getFD().sync();
            } finally { out.close(); }
            if (!tmp.renameTo(f)) throw new IOException("state rename failed");
        }
        void apply(String id, Target t, String desired) throws Exception {
            if (new File(dir, ".ui_stopping").exists()) throw new IOException("uninstall in progress");
            String current = t.get();
            File orig = file(id, "orig"), last = file(id, "last"), pending = file(id, "pending");
            if (!orig.exists()) save(orig, current);
            if (!same(current, desired)) {
                save(pending, desired);
                t.put(desired);
                if (!same(t.get(), desired)) throw new IOException("write not acknowledged: " + id);
            }
            if (!last.exists() || !same(read(last), desired)) save(last, desired);
            pending.delete();
        }
        boolean owns(String id, String current) throws IOException {
            File last = file(id, "last"), pending = file(id, "pending");
            return (last.exists() && same(read(last), current)) ||
                   (pending.exists() && same(read(pending), current));
        }
        void forget(String id) {
            file(id, "orig").delete(); file(id, "last").delete(); file(id, "pending").delete();
        }
        boolean needsRestore(String id, Target t) throws Exception {
            File orig = file(id, "orig");
            if (!orig.exists()) return false;
            String current = t.get();
            if (owns(id, current) && !same(read(orig), current)) return true;
            // Never overwrite a later manual/other-module change.
            forget(id); return false;
        }
        void restore(String id, Target t) throws Exception {
            if (!needsRestore(id, t)) return;
            String original = read(file(id, "orig"));
            t.put(original);
            if (!same(t.get(), original)) throw new IOException("restore not acknowledged: " + id);
            forget(id);
        }
    }

    static final class Spec {
        final String kind, key, value, prop;
        Spec(String line) {
            String[] v = line.split("\\|", -1);
            if (v.length != 5 || !v[1].matches("key_misc_[a-z0-9_]+|key_huawei_headset_fix"))
                throw new IllegalArgumentException("invalid PHH profile row");
            kind = v[0]; key = v[1]; value = v[2]; prop = v[3];
            if (!(kind.equals("boolean") && (value.equals("true") || value.equals("false"))) &&
                !(kind.equals("string") && key.matches("key_misc_sb_padding_(start|end)") && value.equals("1")))
                throw new IllegalArgumentException("invalid PHH profile value");
        }
    }
    static List<Spec> specs(File file) throws IOException {
        List<Spec> result = new ArrayList<Spec>(); Set<String> keys = new HashSet<String>();
        for (String line : new String(bytes(file, 65536), UTF8).split("\n")) {
            line = line.trim(); if (line.length() == 0 || line.startsWith("#")) continue;
            Spec s = new Spec(line);
            if (!keys.add(s.key)) throw new IOException("duplicate PHH key");
            result.add(s);
        }
        return result;
    }
    static byte[] bytes(File file, int limit) throws IOException {
        InputStream in = new FileInputStream(file);
        try { return bytes(in, limit); } finally { in.close(); }
    }
    static byte[] bytes(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] b = new byte[8192]; int n;
        while ((n = in.read(b)) != -1) {
            if (out.size() + n > limit) throw new IOException("input exceeds size bound");
            out.write(b, 0, n);
        }
        return out.toByteArray();
    }

    /* Read only DEX string IDs, not resources/substring guesses. An absent switch
     * is not created just because another PHH fork happened to support it. */
    static int u32(byte[] b, int off) throws IOException {
        if (off < 0 || off > b.length - 4) throw new IOException("invalid DEX offset");
        long n = ((long)b[off] & 255) | (((long)b[off+1] & 255) << 8) |
                 (((long)b[off+2] & 255) << 16) | (((long)b[off+3] & 255) << 24);
        if (n > Integer.MAX_VALUE) throw new IOException("oversized DEX offset");
        return (int)n;
    }
    static Set<String> dexStrings(byte[] b, Set<String> wanted) throws IOException {
        Set<String> found = new HashSet<String>();
        if (b.length < 112 || b[0] != 'd' || b[1] != 'e' || b[2] != 'x' || b[3] != '\n')
            throw new IOException("not a standard DEX");
        int count = u32(b, 56), off = u32(b, 60);
        if (count > b.length / 4 || off > b.length - count * 4) throw new IOException("bad string IDs");
        for (int i = 0; i < count; i++) {
            int p = u32(b, off + 4 * i), lenBytes = 0;
            while (true) {
                if (p >= b.length || ++lenBytes > 5) throw new IOException("bad DEX string length");
                if ((b[p++] & 128) == 0) break;
            }
            int start = p;
            while (p < b.length && b[p] != 0 && p - start < 256) p++;
            if (p < b.length && b[p] == 0) {
                String s = new String(b, start, p-start, UTF8);
                if (wanted.contains(s)) found.add(s);
            }
        }
        return found;
    }
    static Set<String> apkStrings(File apk, Set<String> wanted) throws IOException {
        Set<String> found = new HashSet<String>(); ZipFile zip = new ZipFile(apk);
        try {
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry e = entries.nextElement();
                if (!e.getName().matches("classes([0-9]+)?\\.dex")) continue;
                InputStream in = zip.getInputStream(e);
                try { found.addAll(dexStrings(bytes(in, 64 * 1024 * 1024), wanted)); }
                finally { in.close(); }
            }
        } finally { zip.close(); }
        return found;
    }
    static String menu(String existing, String[] defaults) {
        LinkedHashSet<String> actions = new LinkedHashSet<String>();
        String[] source = existing == null ? defaults : existing.split("\\|");
        for (String action : source) if (action.length() > 0) actions.add(action);
        actions.remove("airplane"); actions.remove("onthego");
        actions.remove("users"); actions.remove("devicecontrols");
        // Keep all unseen actions, including users/devicecontrols; don't force unsupported controls.
        actions.add("power"); actions.add("restart");
        actions.add("screenshot"); actions.add("lockdown"); actions.add("emergency");
        StringBuilder result = new StringBuilder();
        for (String action : actions) { if (result.length() > 0) result.append('|'); result.append(action); }
        return result.toString();
    }

    static Class<?> c(String name) throws ClassNotFoundException { return Class.forName(name); }
    static Object call(String owner, Object obj, String name, Class<?>[] types, Object... args) throws Exception {
        try { return c(owner).getMethod(name, types).invoke(obj, args); }
        catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception)cause;
            throw e;
        }
    }
    static final Class<?>[] NONE = new Class<?>[0];
    static Object field(Object o, String name) throws Exception { return o.getClass().getField(name).get(o); }
    static void skipped(String key, Exception e) {
        // No original setting values or PIN/credential material in diagnostics.
        System.err.println(key + " skipped: " + e.getClass().getSimpleName());
    }

    static final class Android {
        final Object context, resolver, user;
        Android() throws Exception {
            if (call("android.os.Looper", null, "myLooper", NONE) == null)
                call("android.os.Looper", null, "prepareMainLooper", NONE);
            Object thread = call("android.app.ActivityThread", null, "systemMain", NONE);
            context = call("android.app.ActivityThread", thread, "getSystemContext", NONE);
            resolver = call("android.content.Context", context, "getContentResolver", NONE);
            user = call("android.os.UserHandle", null, "of", new Class<?>[]{int.class}, USER);
        }
        boolean unlocked() throws Exception {
            Object manager = call("android.content.Context", context, "getSystemService", new Class<?>[]{String.class}, "user");
            return (Boolean)call("android.os.UserManager", manager, "isUserUnlocked", new Class<?>[]{c("android.os.UserHandle")}, user);
        }
        Object packageContext(String pkg) throws Exception {
            return call("android.content.Context", context, "createPackageContextAsUser",
                new Class<?>[]{String.class, int.class, c("android.os.UserHandle")}, pkg, 2, user);
        }
        Set<String> packageStrings(String pkg, Set<String> wanted) throws Exception {
            Object pc = packageContext(pkg);
            Object ai = call("android.content.Context", pc, "getApplicationInfo", NONE);
            return apkStrings(new File((String)field(ai, "sourceDir")), wanted);
        }
        Target secure(final String key) {
            return new Target() {
                public String get() throws Exception {
                    return (String)call("android.provider.Settings$Secure", null, "getStringForUser",
                        new Class<?>[]{c("android.content.ContentResolver"), String.class, int.class}, resolver, key, USER);
                }
                public void put(String value) throws Exception {
                    boolean ok = (Boolean)call("android.provider.Settings$Secure", null, "putStringForUser",
                        new Class<?>[]{c("android.content.ContentResolver"), String.class, String.class, int.class}, resolver, key, value, USER);
                    if (!ok) throw new IOException("secure write rejected");
                }
            };
        }
        Target lineage(final String key) throws Exception {
            Object pm = call("android.content.Context", context, "getPackageManager", NONE);
            Object provider = call("android.content.pm.PackageManager", pm, "resolveContentProvider",
                new Class<?>[]{String.class, int.class}, "lineagesettings", 0);
            if (provider == null) throw new UnsupportedOperationException("no Lineage provider");
            return new Target() {
                Object request(String op, String value) throws Exception {
                    Object uri = call("android.net.Uri", null, "parse", new Class<?>[]{String.class}, "content://lineagesettings");
                    Object extras = c("android.os.Bundle").getConstructor().newInstance();
                    call("android.os.Bundle", extras, "putInt", new Class<?>[]{String.class, int.class}, "_user", USER);
                    if (op.equals("PUT_secure"))
                        call("android.os.Bundle", extras, "putString", new Class<?>[]{String.class, String.class}, "value", value);
                    return call("android.content.ContentResolver", resolver, "call",
                        new Class<?>[]{c("android.net.Uri"), String.class, String.class, c("android.os.Bundle")}, uri, op, key, extras);
                }
                public String get() throws Exception {
                    Object result = request("GET_secure", null);
                    if (result == null) throw new IOException("Lineage provider unavailable");
                    return (String)call("android.os.Bundle", result, "getString", new Class<?>[]{String.class}, "value");
                }
                public void put(String value) throws Exception { request(value == null ? "DELETE_secure" : "PUT_secure", value); }
            };
        }
        String[] defaultMenu() throws Exception {
            Object resources = call("android.content.Context", context, "getResources", NONE);
            int id = (Integer)call("android.content.res.Resources", resources, "getIdentifier",
                new Class<?>[]{String.class, String.class, String.class}, "config_globalActionsList", "array", "android");
            if (id == 0) throw new UnsupportedOperationException("no default power actions");
            return (String[])call("android.content.res.Resources", resources, "getStringArray", new Class<?>[]{int.class}, id);
        }
        Target autoPin() throws Exception {
            if (!unlocked()) throw new UnsupportedOperationException("owner locked");
            final Object lock = c("com.android.internal.widget.LockPatternUtils").getConstructor(c("android.content.Context")).newInstance(context);
            int type = (Integer)call("com.android.internal.widget.LockPatternUtils", lock, "getCredentialTypeForUser", new Class<?>[]{int.class}, USER);
            if (type != 3) throw new UnsupportedOperationException("not an existing PIN");
            return new Target() {
                public String get() throws Exception {
                    return call("com.android.internal.widget.LockPatternUtils", lock, "isAutoPinConfirmEnabled", new Class<?>[]{int.class}, USER).toString();
                }
                public void put(String value) throws Exception {
                    if (!"true".equals(value) && !"false".equals(value)) throw new IOException("bad PIN flag");
                    boolean old = Boolean.parseBoolean(get()), enabled = Boolean.parseBoolean(value);
                    try {
                        flag(enabled);
                        // Same API sequence as Android Settings. No PIN is requested or read.
                        boolean refreshed = (Boolean)call("com.android.internal.widget.LockPatternUtils", lock, "refreshStoredPinLength", new Class<?>[]{int.class}, USER);
                        if (!refreshed) throw new IOException("PIN metrics unavailable");
                        if (enabled && (Integer)call("com.android.internal.widget.LockPatternUtils", lock, "getPinLength", new Class<?>[]{int.class}, USER) < 6)
                            throw new UnsupportedOperationException("PIN not eligible for auto-confirm");
                    } catch (Exception e) {
                        flag(old);
                        call("com.android.internal.widget.LockPatternUtils", lock, "refreshStoredPinLength", new Class<?>[]{int.class}, USER);
                        throw e;
                    }
                }
                void flag(boolean enabled) throws Exception {
                    call("com.android.internal.widget.LockPatternUtils", lock, "setAutoPinConfirm", new Class<?>[]{boolean.class, int.class}, enabled, USER);
                }
            };
        }
        Target aodOverlay() throws Exception {
            final Object manager = call("android.content.Context", context, "getSystemService", new Class<?>[]{String.class}, "overlay");
            return new Target() {
                final String pkg = "me.phh.treble.overlay.misc.aod_systemui";
                public String get() throws Exception {
                    Object info = call("android.content.om.OverlayManager", manager, "getOverlayInfo", new Class<?>[]{String.class, c("android.os.UserHandle")}, pkg, user);
                    if (info == null) throw new UnsupportedOperationException("AOD overlay not installed");
                    return call("android.content.om.OverlayInfo", info, "isEnabled", NONE).toString();
                }
                public void put(String value) throws Exception {
                    if (!"true".equals(value) && !"false".equals(value)) throw new IOException("bad overlay state");
                    call("android.content.om.OverlayManager", manager, "setEnabled",
                        new Class<?>[]{String.class, boolean.class, c("android.os.UserHandle")}, pkg, Boolean.parseBoolean(value), user);
                }
            };
        }
    }

    static final class Phh {
        final Object prefs;
        final File dir, file;
        final int uid, gid, dirMode, fileMode;
        final Set<String> supported;
        Phh(Android a, List<Spec> specs) throws Exception {
            if (!a.unlocked()) throw new UnsupportedOperationException("owner locked");
            Object pc = a.packageContext(PHH);
            Object ai = call("android.content.Context", pc, "getApplicationInfo", NONE);
            Set<String> wanted = new HashSet<String>();
            for (Spec s : specs) wanted.add(s.key);
            wanted.add("persist.sys.phh.securize");
            supported = apkStrings(new File((String)field(ai, "sourceDir")), wanted);
            // The old action has the same preference key, but is NOT this switch.
            File handler = new File("/system/bin/phh-prop-handler.sh");
            if (!supported.contains("persist.sys.phh.securize") || !handler.isFile() ||
                !new String(bytes(handler, 1024*1024), UTF8).contains("persist.sys.phh.securize"))
                supported.remove("key_misc_securize");
            File data = new File((String)field(ai, "dataDir")).getCanonicalFile();
            dir = new File(data, "shared_prefs"); file = new File(dir, PREFS + ".xml");
            if (!dir.getCanonicalFile().equals(dir) || !file.getCanonicalFile().equals(file))
                throw new IOException("unexpected preference symlink");
            uid = (Integer)field(ai, "uid");
            int[] dm = metadata(dir, uid, uid, 0700), fm = metadata(file, uid, uid, 0600);
            gid = fm[1]; dirMode = dm[2]; fileMode = fm[2];
            if (!dir.exists() && !dir.mkdir()) throw new IOException("cannot create preference directory");
            permissions(dir, uid, dm[1], dirMode);
            prefs = call("android.content.Context", pc, "getSharedPreferences", new Class<?>[]{String.class, int.class}, PREFS, 0);
        }
        static int[] metadata(File f, int uid, int gid, int mode) throws Exception {
            if (!f.exists()) return new int[]{uid, gid, mode};
            Object stat = call("android.system.Os", null, "stat", new Class<?>[]{String.class}, f.getPath());
            return new int[]{(Integer)field(stat, "st_uid"), (Integer)field(stat, "st_gid"), (Integer)field(stat, "st_mode") & 0777};
        }
        static void permissions(File f, int uid, int gid, int mode) throws Exception {
            call("android.system.Os", null, "chown", new Class<?>[]{String.class, int.class, int.class}, f.getPath(), uid, gid);
            call("android.system.Os", null, "chmod", new Class<?>[]{String.class, int.class}, f.getPath(), mode);
            if (!(Boolean)call("android.os.SELinux", null, "restorecon", new Class<?>[]{File.class}, f))
                throw new IOException("preference SELinux label not restored");
        }
        Target target(final Spec s) {
            return new Target() {
                public String get() throws Exception {
                    Map<?, ?> all = (Map<?, ?>)call("android.content.SharedPreferences", prefs, "getAll", NONE);
                    Object value = all.get(s.key);
                    if (value == null) return null;
                    if (s.kind.equals("boolean") ? !(value instanceof Boolean) : !(value instanceof String))
                        throw new IOException("unexpected preference type");
                    return value.toString();
                }
                public void put(String value) throws Exception {
                    Object editor = call("android.content.SharedPreferences", prefs, "edit", NONE);
                    if (value == null) call("android.content.SharedPreferences$Editor", editor, "remove", new Class<?>[]{String.class}, s.key);
                    else if (s.kind.equals("boolean")) {
                        if (!value.equals("true") && !value.equals("false")) throw new IOException("bad boolean");
                        call("android.content.SharedPreferences$Editor", editor, "putBoolean", new Class<?>[]{String.class, boolean.class}, s.key, Boolean.parseBoolean(value));
                    } else call("android.content.SharedPreferences$Editor", editor, "putString", new Class<?>[]{String.class, String.class}, s.key, value);
                    try {
                        if (!(Boolean)call("android.content.SharedPreferences$Editor", editor, "commit", NONE))
                            throw new IOException("preference commit failed");
                    } finally {
                        if (file.exists()) permissions(file, uid, gid, fileMode);
                        File bak = new File(file.getPath() + ".bak");
                        if (bak.exists()) permissions(bak, uid, gid, fileMode);
                    }
                }
            };
        }
    }

    static void setting(State state, String id, Target t, String value, boolean restore) {
        try { if (restore) state.restore(id, t); else state.apply(id, t, value); }
        catch (Exception e) { skipped(id, e); }
    }
    static void framework(Android a, State state, boolean restore) {
        setting(state, "secure.0.lock_screen_lock_after_timeout", a.secure("lock_screen_lock_after_timeout"), "0", restore);
        try {
            Target actions = a.lineage("power_menu_actions");
            String desired = restore ? null : menu(actions.get(), a.defaultMenu());
            setting(state, "lineage.0.power_menu_actions", actions, desired, restore);
            for (String key : Arrays.asList("advanced_reboot", "advanced_reboot_secured"))
                setting(state, "lineage.0." + key, a.lineage(key), "1", restore);
        } catch (Exception e) { skipped("power menu", e); }
    }
    static int run(File dir, File profile, String mode) throws Exception {
        State state = new State(dir); List<Spec> specs = specs(profile); Android a = new Android();
        if (mode.equals("ready")) return a.unlocked() ? 0 : 2;
        if (mode.equals("apply-settings") || mode.equals("restore-settings")) {
            boolean restore = mode.startsWith("restore"); framework(a, state, restore);
            if (restore) try { setting(state, "pin.0.auto_confirm", a.autoPin(), "true", true); }
            catch (Exception e) { skipped("auto-confirm", e); }
            return 0;
        }
        if (mode.equals("apply-unlocked")) {
            try { setting(state, "pin.0.auto_confirm", a.autoPin(), "true", false); }
            catch (Exception e) { skipped("auto-confirm", e); }
            return 0;
        }
        if (!(mode.equals("apply-probe") || mode.equals("restore-probe") || mode.equals("apply-prefs") || mode.equals("restore-prefs")))
            throw new IllegalArgumentException("unknown operation");
        Phh phh;
        try { phh = new Phh(a, specs); }
        catch (Exception e) {
            if (e.getClass().getName().endsWith("NameNotFoundException")) { System.out.println("ABSENT"); return 0; }
            throw e;
        }
        boolean restore = mode.startsWith("restore"), probe = mode.endsWith("probe"), change = false;
        for (Spec s : specs) {
            if (!phh.supported.contains(s.key)) continue;
            String id = "pref.0." + s.key; Target t = phh.target(s);
            try {
                if (probe) {
                    if (restore) change |= state.needsRestore(id, t);
                    else if (!State.same(t.get(), s.value)) change = true;
                    else state.apply(id, t, s.value); // snapshot unchanged values without stopping PHH
                } else if (restore) state.restore(id, t);
                else state.apply(id, t, s.value);
            } catch (Exception e) { skipped(s.key, e); }
        }
        if (probe) System.out.println(change ? "CHANGE" : "SAME");
        return 0;
    }
    public static void main(String[] args) {
        int result = 1;
        try {
            if (args.length != 3 || !new File(args[0]).isDirectory()) throw new IllegalArgumentException("usage: STATE PROFILE OP");
            result = run(new File(args[0]), new File(args[1]), args[2]);
        } catch (Exception e) { skipped("ROM defaults", e); }
        System.exit(result); // No lingering Binder/Looper threads after the finite task.
    }
}
