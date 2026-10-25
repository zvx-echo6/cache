package co.cache.cache

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    // Recent Android versions let the user switch network access (INTERNET) off, and an app updated from a build
    // that never asked for it does not get it; opening even the map's tile server port on this phone then fails.
    // The map screen asks through this channel when that happens.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/network_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        if (pending != null) {
                            result.success(false)
                        } else {
                            pending = result
                            requestPermissions(arrayOf(Manifest.permission.INTERNET), REQUEST_CODE)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun granted() =
        checkSelfPermission(Manifest.permission.INTERNET) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == REQUEST_CODE) {
            pending?.success(granted())
            pending = null
        }
    }

    companion object {
        private const val REQUEST_CODE = 4210
    }
}
