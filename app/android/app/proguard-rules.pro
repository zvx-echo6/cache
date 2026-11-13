# Android Auto (car/CacheCarAppService.kt, HostNavigation): after the host stops Cache's navigation, "navigation ended" can only
# be sent by setting the Car App Library's own flag back, a private field found by its name. Keep that name in the release build.
-keepclassmembers class androidx.car.app.navigation.NavigationManager {
    boolean mIsNavigating;
}

# ML Kit text recognition (OCR of scanned PDF pages). ML Kit makes its component registrars (CommonComponentRegistrar,
# VisionCommonRegistrar, TextRegistrar) by reflection, by class name from the manifest, with the no-argument constructor.
# firebase-components keeps the classes but not their constructors, and R8 full mode drops an unused constructor. Then
# MlKitContext has no text recognizer and TextRecognition.getClient throws a NullPointerException: every scanned page failed
# in the release build (seen on the Pixel, build 100104). The release-mode guard is .github/workflows/ocr-release.yml.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    <init>();
}
