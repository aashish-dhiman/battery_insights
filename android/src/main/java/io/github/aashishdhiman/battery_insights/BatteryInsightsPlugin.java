package io.github.aashishdhiman.battery_insights;

import android.Manifest;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.BatteryManager;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Reads the battery and thermal state the OS already keeps, on demand.
 *
 * Nothing here registers a receiver, holds a wake lock or schedules work: the
 * battery intent is the sticky copy the system caches (a null receiver only
 * returns it), and each BatteryManager/PowerManager property is a single
 * binder call. The Dart side only calls {@code read} when the app is already
 * awake, so measuring adds no drain of its own.
 *
 * Every value is optional. Each group is read in its own try block and a value
 * the device does not support is left out of the map rather than sent as a
 * sentinel, so one OEM quirk costs that value and nothing else.
 */
public class BatteryInsightsPlugin implements FlutterPlugin, MethodCallHandler {
    // BatteryManager.EXTRA_CYCLE_COUNT, API 34. Spelled out so the lookup is a
    // plain missing extra on older devices.
    private static final String EXTRA_CYCLE_COUNT = "android.os.extra.CYCLE_COUNT";

    private MethodChannel channel;
    private Context context;

    // Design capacity never changes, so it is read once per process. NaN means
    // "tried and unavailable" so a failing device is not re-probed each read.
    private static double designCapacityMah = -1;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "battery_insights");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        if (!"read".equals(call.method)) {
            result.notImplemented();
            return;
        }
        try {
            result.success(read());
        } catch (Throwable e) {
            result.error("read_failed", String.valueOf(e.getMessage()), null);
        }
    }

    private Map<String, Object> read() {
        final Map<String, Object> out = new HashMap<>();
        final Context ctx = context;
        if (ctx == null) return out;
        // Lets the debug view say why a value is missing (too old an Android
        // vs. not supported by this device).
        out.put("sdkInt", Build.VERSION.SDK_INT);

        try {
            final Intent battery = ctx.registerReceiver(
                    null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery != null) readBatteryIntent(battery, out);
        } catch (Throwable ignored) {
        }

        try {
            final BatteryManager bm = (BatteryManager) ctx.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                // Unsupported properties come back as Integer.MIN_VALUE (or 0
                // on some OEMs); both are dropped so Dart sees null, not zero.
                putIfValid(out, "chargeCounter", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER));
                putIfValid(out, "currentNow", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW));
            }
        } catch (Throwable ignored) {
        }

        try {
            final PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null) readPowerManager(pm, out);
        } catch (Throwable ignored) {
        }

        try {
            readScreen(ctx, out);
        } catch (Throwable ignored) {
        }

        try {
            readNetwork(ctx, out);
        } catch (Throwable ignored) {
        }

        final double design = designCapacity(ctx);
        if (!Double.isNaN(design)) out.put("designCapacityMah", design);
        return out;
    }

    /**
     * The factory-rated capacity from the OEM's power profile. There is no
     * public API for it: {@code PowerProfile} is a hidden class, reached by
     * reflection (on the non-SDK "unsupported" list — allowed, logs a warning).
     * AOSP's placeholder of 1000 mAh, and anything implausible, count as
     * unavailable.
     */
    private static synchronized double designCapacity(Context ctx) {
        if (designCapacityMah >= 0 || Double.isNaN(designCapacityMah)) return designCapacityMah;
        designCapacityMah = Double.NaN;
        try {
            final Class<?> profile = Class.forName("com.android.internal.os.PowerProfile");
            final Object instance = profile.getConstructor(Context.class).newInstance(ctx);
            final Object value = profile.getMethod("getBatteryCapacity").invoke(instance);
            if (value instanceof Number) {
                final double mah = ((Number) value).doubleValue();
                if (mah > 1000 && mah < 30000) designCapacityMah = mah;
            }
        } catch (Throwable ignored) {
        }
        return designCapacityMah;
    }

    private static void readBatteryIntent(Intent battery, Map<String, Object> out) {
        final int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        final int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
        if (level >= 0 && scale > 0) out.put("level", level * 100.0 / scale);
        out.put("plugged", battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0);
        putIfValid(out, "temperature", battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE));
        putIfValid(out, "voltage", battery.getIntExtra(BatteryManager.EXTRA_VOLTAGE, Integer.MIN_VALUE));

        final String health = healthName(battery.getIntExtra(BatteryManager.EXTRA_HEALTH, -1));
        if (health != null) out.put("health", health);

        final int cycles = battery.getIntExtra(EXTRA_CYCLE_COUNT, -1);
        if (cycles >= 0) out.put("cycleCount", cycles);
    }

    private static void readPowerManager(PowerManager pm, Map<String, Object> out) {
        out.put("powerSave", pm.isPowerSaveMode());
        out.put("screenOn", pm.isInteractive());

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                out.put("thermalStatus", pm.getCurrentThermalStatus());
            } catch (Throwable ignored) {
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                // NaN when unsupported, or when called again within a second —
                // a burst of transitions simply goes without it.
                final float headroom = pm.getThermalHeadroom(0);
                if (!Float.isNaN(headroom) && !Float.isInfinite(headroom) && headroom >= 0) {
                    out.put("thermalHeadroom", (double) headroom);
                }
            } catch (Throwable ignored) {
            }
        }
    }

    /**
     * Backlight level as a percentage of the device's own maximum, and whether
     * auto-brightness is on (then the stored level is the user's last manual
     * one, not what the screen shows, so it is not sent). The maximum comes
     * from the framework resource OEMs set — 255 on AOSP, up to 4095 on some —
     * falling back to 255. This is the backlight value, which tracks power; it
     * is not the slider position, which Android maps on a curve.
     */
    private static void readScreen(Context ctx, Map<String, Object> out) {
        final ContentResolver cr = ctx.getContentResolver();
        final int mode = Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, -1);
        if (mode >= 0) {
            out.put("brightnessAuto", mode == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC);
        }
        final int level = Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS, -1);
        if (level < 0) return;
        int max = 255;
        try {
            final Resources res = Resources.getSystem();
            final int id = res.getIdentifier("config_screenBrightnessSettingMaximum", "integer", "android");
            if (id != 0) {
                final int configured = res.getInteger(id);
                if (configured > 0) max = configured;
            }
        } catch (Throwable ignored) {
        }
        if (level > max) max = level;
        out.put("brightnessPct", level * 100.0 / max);
    }

    /** Transport of the active network: wifi, cell, ethernet, other or none. */
    private static void readNetwork(Context ctx, Map<String, Object> out) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        if (ctx.checkSelfPermission(Manifest.permission.ACCESS_NETWORK_STATE)
                != PackageManager.PERMISSION_GRANTED) return;
        final ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) return;
        final Network network = cm.getActiveNetwork();
        final NetworkCapabilities caps = network == null ? null : cm.getNetworkCapabilities(network);
        if (caps == null) {
            out.put("network", "none");
        } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            out.put("network", "wifi");
        } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            out.put("network", "cell");
        } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            out.put("network", "ethernet");
        } else {
            out.put("network", "other");
        }
    }

    private static String healthName(int health) {
        switch (health) {
            case BatteryManager.BATTERY_HEALTH_GOOD: return "good";
            case BatteryManager.BATTERY_HEALTH_OVERHEAT: return "overheat";
            case BatteryManager.BATTERY_HEALTH_DEAD: return "dead";
            case BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE: return "over_voltage";
            case BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE: return "failure";
            case BatteryManager.BATTERY_HEALTH_COLD: return "cold";
            default: return null;
        }
    }

    private static void putIfValid(Map<String, Object> out, String key, int value) {
        if (value != Integer.MIN_VALUE && value != 0) out.put(key, value);
    }
}
