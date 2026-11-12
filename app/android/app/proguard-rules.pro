# Android Auto (car/CacheCarAppService.kt, HostNavigation): after the host stops Cache's navigation, "navigation ended" can only
# be sent by setting the Car App Library's own flag back, a private field found by its name. Keep that name in the release build.
-keepclassmembers class androidx.car.app.navigation.NavigationManager {
    boolean mIsNavigating;
}
