import '../notebook/notebook_state.dart' show PrivateSharing;
import 'sharing_state.dart';

/// In a browser, the private notebooks' "Include in sync and sharing" switches are Cache Server's: its notebook sync keeps them and is
/// the one that leaves a private notebook out of the share, so this reads them from the server's sharing state and sets them there
/// (`sharing.set_private`). The notebooks' pages and the Notebooks kind page then list and switch them as on a phone, where
/// NotebookConnections keeps them.
class ServerPrivateSharing implements PrivateSharing {
  ServerPrivateSharing(this.sharing);

  final SharingState sharing;

  @override
  bool included(String notebookId) => sharing.privateIncluded.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) => sharing.setPrivateIncluded(notebookId, on);
}
