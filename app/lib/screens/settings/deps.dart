import '../../app_state.dart';
import '../../browse/browse_state.dart';
import '../../car/car_voice_access.dart';
import '../../chat/chat_controller.dart';
import '../../location/location_service.dart';
import '../../maps/maps_state.dart';
import '../../settings/hub.dart';
import '../../sources/sources_state.dart';
import '../../video/video_state.dart';

/// Everything the Settings pages read and change, gathered once so a page takes one argument.
class SettingsDeps {
  const SettingsDeps({
    required this.app,
    required this.chat,
    required this.sources,
    required this.maps,
    required this.video,
    required this.browse,
    required this.location,
    required this.hub,
    this.onOpenAsk,
    this.carVoice,
  });

  final AppState app;
  final ChatController chat;
  final SourcesState sources;
  final MapsState maps;
  final VideoState video;
  final BrowseState browse;
  final LocationService location;
  final SettingsHub hub;

  /// Called after a saved conversation is chosen, to bring the Ask screen forward.
  final void Function()? onOpenAsk;

  /// Voice search from the car, the iPhone's permissions; null leaves its row out (Settings > the row "Search by voice from the car").
  final CarVoiceAccess? carVoice;
}
