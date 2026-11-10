import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.happylittlellc.cache"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // A side-by-side test build (android-test-apk.yml sets the Gradle property cacheTestApk=true): its own package
        // (com.happylittlellc.cache.test, so its own data) and the label "Cache test". Plugin providers use ${applicationId}.
        val testApk = (project.findProperty("cacheTestApk") as String?) == "true"
        applicationId = if (testApk) "com.happylittlellc.cache.test" else "com.happylittlellc.cache"
        manifestPlaceholders["appLabel"] = if (testApk) "Cache test" else "Cache"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28 // llama.cpp needs API 28
        // 64-bit ARM only: the search core, llama, libzim, Valhalla and iroh are built for arm64-v8a only, so an x86_64 slice would load but not work.
        ndk { abiFilters += listOf("arm64-v8a") }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // The native layer finds its CPU variant libraries (libggml-cpu-*.so) by scanning the app's
            // library folder, so they must be installed there as real files.
            useLegacyPackaging = true
            // Not shipped: on the Pixel 8 (Tensor G3) the SVE2 variants read prompts at about half the
            // speed of armv8.6_1, and ggml would prefer them. Keep every armv8.x variant.
            excludes += "**/libggml-cpu-android_armv9*.so"
        }
    }

    // Release signing: the Play upload key, read from android/key.properties (never committed; see .gitignore).
    // Without that file (any machine but the release builder) release builds are signed with the debug key.
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        if (keyProps.getProperty("storeFile") != null) {
            create("upload") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
        }
    }

    // The car screen's JVM tests (src/test, Robolectric): android-car.yml runs them in CI.
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Android Auto is in the code but off by default: its manifest entries (src/car/AndroidManifest.xml: the CarAppService, the
// navigation intents, the car permissions) are merged only with -PcacheAndroidAuto=true. The release on Play stays out of
// Android Auto until it ships together with CarPlay (owner, 2026-11-08); the test APK and the car tests turn it on.
val androidAuto = (project.findProperty("cacheAndroidAuto") as String?) == "true"
if (androidAuto) {
    androidComponents {
        onVariants { variant -> variant.sources.manifests.addStaticManifestFile("src/car/AndroidManifest.xml") }
    }
}

// The car screen's Robolectric tests read the merged assets, which the Flutter plugin's copy task writes: let it run first.
tasks.configureEach {
    if (name == "packageDebugUnitTestForUnitTest") dependsOn("copyFlutterAssetsDebug")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // The whole-route picture during guidance (RouteSnapshot.kt) uses MapLibre's offscreen map snapshotter. This is the same
    // artifact, at the same version, that the maplibre_gl plugin already brings in, so no new code ships; tools/check_maplibre_pin.py
    // (run by the Tests workflow) fails if the two ever differ. The plugin leaves out the Vulkan "android-sdk" for the same reason.
    implementation("org.maplibre.gl:android-sdk-opengl:13.5.0") {
        exclude(group = "org.maplibre.gl", module = "android-sdk")
    }
    // Android Auto (approved 2026-11-08): the Android for Cars App Library, stable 1.7.0, and its Android Auto part. The car map
    // (car/CarMapRenderer.kt) draws with the MapLibre artifact above.
    implementation("androidx.car.app:app:1.7.0")
    implementation("androidx.car.app:app-projected:1.7.0")

    // Tests only, never in the APK (android-car.yml checks the release classpath): approved 2026-11-08.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.car.app:app-testing:1.7.0")
}
