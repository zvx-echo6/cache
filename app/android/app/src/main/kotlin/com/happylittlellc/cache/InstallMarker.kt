package com.happylittlellc.cache

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The device-only half of the install marker (lib/sharing/install_marker.dart): a file in the app's no-backup folder, which
 * Android neither backs up nor carries to another phone. Set on the engine as it is made (car/SharedEngine.kt), so it is
 * answered with or without a phone screen.
 *
 * "read" gives the install id or null; "write" keeps one; "excludeFromBackup" does nothing here (Android's backup rules are in
 * res/xml: data_extraction_rules.xml and full_backup_content.xml).
 */
object InstallMarker {
    const val CHANNEL = "co.cache/install_marker"
    private const val FILE = "install-id"

    fun attach(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> {
                    val f = File(app.noBackupFilesDir, FILE)
                    result.success(if (f.isFile) f.readText().trim().ifEmpty { null } else null)
                }
                "write" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrBlank()) {
                        result.error("bad_id", "no id given", null)
                    } else {
                        val f = File(app.noBackupFilesDir, FILE)
                        val tmp = File(app.noBackupFilesDir, "$FILE.tmp")
                        tmp.writeText(id)
                        if (!tmp.renameTo(f)) {
                            f.writeText(id)
                            tmp.delete()
                        }
                        result.success(null)
                    }
                }
                "excludeFromBackup" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }
}
