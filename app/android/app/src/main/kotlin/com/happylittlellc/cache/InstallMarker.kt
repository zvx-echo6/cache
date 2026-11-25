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
 *
 * "readIdentity" / "writeIdentity": the second copy of the device's sync key with its install id (lib/sharing/identity_keep.dart),
 * one text in the same no-backup folder. "readIdentity" gives null only when the file is missing; a file that cannot be read is
 * an error, so the app never takes it for "every copy is gone".
 */
object InstallMarker {
    const val CHANNEL = "co.cache/install_marker"
    private const val FILE = "install-id"
    private const val IDENTITY = "identity-keep"

    /** Written under a temporary name and renamed over the file, so nothing reads half of it. */
    private fun keep(dir: File, name: String, text: String) {
        val f = File(dir, name)
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(f)) {
            f.writeText(text)
            tmp.delete()
        }
    }

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
                "readIdentity" -> {
                    val f = File(app.noBackupFilesDir, IDENTITY)
                    try {
                        result.success(if (f.exists()) f.readText() else null)
                    } catch (e: Exception) {
                        result.error("identity_read", e.message, null)
                    }
                }
                "writeIdentity" -> {
                    val v = call.argument<String>("value")
                    if (v.isNullOrBlank()) {
                        result.error("bad_value", "no value given", null)
                    } else {
                        try {
                            keep(app.noBackupFilesDir, IDENTITY, v)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("identity_write", e.message, null)
                        }
                    }
                }
                "excludeFromBackup" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }
}
