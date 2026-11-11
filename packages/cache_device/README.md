# cache_device

Cache's battery and heat readings on Android, on the channel `co.cache/battery`, method `read`:
`{"percent": 0..100 or -1, "charging": bool, "thermal": "nominal" | "light" | "moderate" | "severe" | "critical" | "unknown",
"headroom": 0.0.. (Android 11 and later) or absent}`. The Dart side is the app's `lib/platform/battery.dart`.

It is a Flutter plugin so it is registered in every engine: the app's and the WorkManager background engine, so background
work reads the same battery and heat as the app and follows the same rules. iOS answers the same channel from the app's
AppDelegate.
