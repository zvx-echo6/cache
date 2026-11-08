package co.cache.cache_ocr;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import androidx.annotation.NonNull;

import com.google.android.gms.tasks.Tasks;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Text recognition with Google ML Kit's bundled Latin model, one page at a time on one background thread (a page image is
 * about 34 MB decoded at 300 dpi; one at a time keeps memory flat). Answers `info`, `recognize` and `memory` on
 * co.cache/cache_ocr.
 */
public class CacheOcrPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    /** Goes into book.ocr; lowercase and stable. */
    static final String ENGINE = "mlkit";
    /** The ML Kit library version (android/build.gradle pins the same). */
    static final String VERSION = "16.0.1";

    private MethodChannel channel;
    private ExecutorService worker;
    private TextRecognizer recognizer;
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "co.cache/cache_ocr");
        channel.setMethodCallHandler(this);
        worker = Executors.newSingleThreadExecutor();
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        final ExecutorService w = worker;
        w.execute(() -> {
            if (recognizer != null) recognizer.close();
            recognizer = null;
        });
        w.shutdown();
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "info": {
                Map<String, Object> info = new HashMap<>();
                info.put("engine", ENGINE);
                info.put("version", VERSION);
                info.put("languages", Collections.singletonList("latin"));
                result.success(info);
                break;
            }
            case "memory": {
                long[] m = memory();
                Map<String, Object> out = new HashMap<>();
                out.put("current_bytes", m[0]);
                out.put("peak_bytes", m[1]);
                result.success(out);
                break;
            }
            case "recognize": {
                final String path = call.argument("path");
                worker.execute(() -> recognize(path, result));
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private void recognize(String path, MethodChannel.Result result) {
        try {
            if (path == null || !new File(path).isFile()) {
                fail(result, "no_file", "No image at " + path);
                return;
            }
            final long[] before = memory();
            final long t0 = SystemClock.elapsedRealtimeNanos();
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inPreferredConfig = Bitmap.Config.ARGB_8888;
            Bitmap bitmap = BitmapFactory.decodeFile(path, o);
            if (bitmap == null) {
                fail(result, "bad_image", "Not an image: " + path);
                return;
            }
            final long t1 = SystemClock.elapsedRealtimeNanos();
            if (recognizer == null) recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
            Text text;
            try {
                text = Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)));
            } finally {
                bitmap.recycle();
            }
            final long t2 = SystemClock.elapsedRealtimeNanos();
            final long[] after = memory();

            // ML Kit gives blocks in reading order, and each block's lines top to bottom.
            List<Map<String, Object>> lines = new ArrayList<>();
            for (Text.TextBlock block : text.getTextBlocks()) {
                for (Text.Line line : block.getLines()) {
                    Map<String, Object> l = new HashMap<>();
                    l.put("text", line.getText());
                    l.put("confidence", (double) line.getConfidence());
                    lines.add(l);
                }
            }
            Map<String, Object> stats = new HashMap<>();
            stats.put("decode_ms", (t1 - t0) / 1e6);
            stats.put("recognize_ms", (t2 - t1) / 1e6);
            stats.put("before_bytes", before[0]);
            stats.put("after_bytes", after[0]);
            stats.put("peak_bytes", after[1]);
            Map<String, Object> out = new HashMap<>();
            out.put("lines", lines);
            out.put("stats", stats);
            main.post(() -> result.success(out));
        } catch (Throwable e) {
            fail(result, "engine", String.valueOf(e));
        }
    }

    private void fail(MethodChannel.Result result, String code, String message) {
        main.post(() -> result.error(code, message, null));
    }

    /** The process's resident set now and its peak (VmRSS and VmHWM from /proc/self/status), in bytes. */
    private static long[] memory() {
        long rss = 0, hwm = 0;
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/status"))) {
            String s;
            while ((s = r.readLine()) != null) {
                if (s.startsWith("VmRSS:")) rss = kb(s);
                else if (s.startsWith("VmHWM:")) hwm = kb(s);
            }
        } catch (Exception ignored) {
        }
        return new long[] {rss, hwm};
    }

    private static long kb(String line) {
        String[] parts = line.trim().split("\\s+");
        try {
            return Long.parseLong(parts[1]) * 1024L;
        } catch (Exception e) {
            return 0;
        }
    }
}
