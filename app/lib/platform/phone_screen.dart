import 'package:flutter/widgets.dart';

/// The phone's interface, built anew for each phone screen.
///
/// On Android the app outlives its screen. The engine the app runs in is kept for the life of the process
/// (android/.../car/SharedEngine.kt), so when Android closes the phone's screen (the activity: Back from the first page, the
/// app swiped away, the system taking it) the app goes on running, and the next phone screen or car session attaches to it.
/// `main` runs once per process, not once per screen.
///
/// What the app holds outside the interface stays as it is: the conversation, a route and its guidance, downloads, the models.
/// The interface does not. When a screen has gone (the lifecycle said detached) and a new one comes, the interface made for the
/// old screen is taken down and [builder] builds it again from the start. Its pages, map views and web views belonged to the old
/// screen: a map view is rebuilt by its plugin with the style it was first made with, a web view keeps the closed screen as its
/// context. A new interface has none of that, and each new screen starts as the first one did.
///
/// The old interface is taken down in one frame and the new one is built in the next, so everything of the old is disposed
/// before anything of the new starts. That one frame shows [placeholder].
///
/// [onScreen] is called each time a phone screen comes to the front for the first time: the first screen of this run when it
/// came after this widget was made (so also when the car started Cache and the phone app was opened later), and each new
/// screen after one went. It is where what the start did for the screen it expected is done again.
class PhoneScreenScope extends StatefulWidget {
  const PhoneScreenScope({super.key, required this.builder, this.placeholder = const SizedBox.shrink(), this.onScreen});

  final WidgetBuilder builder;
  final Widget placeholder;
  final VoidCallback? onScreen;

  @override
  State<PhoneScreenScope> createState() => _PhoneScreenScopeState();
}

class _PhoneScreenScopeState extends State<PhoneScreenScope> {
  late final AppLifecycleListener _lifecycle;

  /// A phone screen has been in front in this run.
  bool _seen = false;

  /// The screen went (detached) and none has come since.
  bool _gone = false;

  /// The interface is built (false for the one frame between the old screen's interface and the new one's).
  bool _up = true;

  /// Which screen the interface is for: a new one never takes over what the last one built.
  int _screen = 0;

  @override
  void initState() {
    super.initState();
    _seen = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(onStateChange: _onState);
  }

  void _onState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _gone = true;
      return;
    }
    // Only a screen in front counts. An Android engine starts in the state detached, also when the car starts Cache with the
    // phone app closed, and only an activity changes it: the car side never speaks of the lifecycle (car/SharedEngine.kt).
    if (state != AppLifecycleState.resumed) return;
    if (_seen && !_gone) return; // the same screen, back in front
    final again = _gone;
    _seen = true;
    _gone = false;
    widget.onScreen?.call();
    if (!again) return;
    setState(() {
      _up = false;
      _screen++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _up = true);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _up ? KeyedSubtree(key: ValueKey<int>(_screen), child: widget.builder(context)) : widget.placeholder;
}

/// Whether no phone screen is there, going by the lifecycle state [screen]. An Android engine starts in the state detached and
/// stays in it until an activity comes: with the phone app closed and the car starting Cache, for as long as the app runs.
/// (Null: the platform has said nothing yet.) A phone screen that was open and has been closed reads the same.
bool noPhoneScreen(AppLifecycleState? screen) => screen == null || screen == AppLifecycleState.detached;

/// Whether nothing shows the app after the car has left: it still takes itself to be in front ([inFront]: true from its start
/// until the phone's screen is hidden), and no phone screen is there to ever say otherwise ([screen], see [noPhoneScreen]).
///
/// That is the one case of Android Auto starting Cache with the phone app closed: the app then goes to the back by itself
/// (main.dart). With a phone screen in front it stays as it is; with one in the back or closed it already went to the back.
bool nothingShowsTheApp({required bool inFront, required AppLifecycleState? screen}) => inFront && noPhoneScreen(screen);
