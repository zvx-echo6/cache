// A JVM smoke test of the LiteRT-LM Session API the Cache test APK uses (app/android/app/src/litert), run by
// .github/workflows/litert-smoke.yml on a CI runner: nothing here is part of the app.
plugins {
    kotlin("jvm") version "2.3.20"
    application
}

repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("com.google.ai.edge.litertlm:litertlm-jvm:0.19.1")
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("SmokeKt")
}
