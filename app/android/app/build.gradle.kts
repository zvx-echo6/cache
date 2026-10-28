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
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.happylittlellc.cache"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28 // llama.cpp needs API 28
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
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
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
