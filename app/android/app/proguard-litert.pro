# Used only with -PcacheLiteRt=true (test APK): LiteRT-LM's native code calls these classes by name, and the bridge is found
# by name from MainActivity.
-keep class com.google.ai.edge.litertlm.** { *; }
-keep class com.happylittlellc.cache.litert.** { *; }
-dontwarn com.google.ai.edge.litertlm.**
