package co.cache.cache_device;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.PowerManager;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Battery level, whether the phone is plugged in, and how warm it is, on co.cache/battery ("read"). Long automatic work (search
 * indexes, adding PDFs) waits for charging or enough battery, eases off as the phone warms and pauses when it is hot. A plugin,
 * so every engine has it: the app's and WorkManager's background engine read the same values. The sticky battery broadcast
 * answers at once and needs no permission.
 */
public class CacheDevicePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "co.cache/battery");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if ("read".equals(call.method)) {
            result.success(battery());
        } else {
            result.notImplemented();
        }
    }

    private Map<String, Object> battery() {
        final Intent status = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        final int level = status == null ? -1 : status.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        final int scale = status == null ? -1 : status.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
        final int plugged = status == null ? 0 : status.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
        final int percent = level >= 0 && scale > 0 ? level * 100 / scale : -1;
        final Map<String, Object> out = new HashMap<>();
        out.put("percent", percent);
        out.put("charging", plugged != 0);
        out.put("thermal", thermal());
        final Double h = headroom();
        if (h != null) out.put("headroom", h);
        return out;
    }

    /** How warm the phone is (Android 10 and later). */
    private String thermal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unknown";
        final PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (pm == null) return "unknown";
        switch (pm.getCurrentThermalStatus()) {
            case PowerManager.THERMAL_STATUS_NONE:
                return "nominal";
            case PowerManager.THERMAL_STATUS_LIGHT:
                return "light";
            case PowerManager.THERMAL_STATUS_MODERATE:
                return "moderate";
            case PowerManager.THERMAL_STATUS_SEVERE:
                return "severe";
            default:
                return "critical";
        }
    }

    /** The thermal headroom over the next 10 seconds (Android 11 and later; 1.0 is where the phone throttles hard). */
    private Double headroom() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null;
        final PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (pm == null) return null;
        final float h = pm.getThermalHeadroom(10);
        return Float.isNaN(h) ? null : (double) h;
    }
}
