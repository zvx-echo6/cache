package com.happylittlellc.cache

/** The launch intent extra (a JSON object) that carries the engine settings of a test APK to the app's Dart side. */
const val BENCH_ENGINE_EXTRA = "cache_engine"

/**
 * The gate: a build that is not the test APK never reads the intent (read is not called) and always answers null; the test APK
 * answers what read gives (the extra, or null when the launch carried none).
 */
fun benchEngineExtra(testApk: Boolean, read: () -> String?): String? = if (testApk) read() else null
