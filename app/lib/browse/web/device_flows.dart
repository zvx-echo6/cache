import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/download_confirm.dart';
import '../../screens/libraries_screen.dart' show askLibrarySettings, askUpdateLibrary;
import '../../sources/libraries_state.dart';
import 'device_library.dart';
import 'local_files.dart';

/// Adds a file from this computer to the Library: the chosen or dropped file is checked by its ending, the device's room is checked,
/// and the file is uploaded; a library package is then added by the app itself, with the usual prompts. Call it straight from a tap
/// (no awaiting first) when no file is given, so the browser opens its file chooser.
Future<void> addFromComputer(BuildContext context, {required DeviceLibrary device, LibrariesState? libraries, LocalFile? dropped}) async {
  if (device.upload?.running == true) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final file = dropped ?? await pickLocalFile(accept: [...kZimEndings, ...kLibraryEndings]);
  if (file == null) return;
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  final why = device.whyNot(file);
  if (why != null) {
    device.refuse(why);
    say('${file.name} was not uploaded. It is not a library file.');
    return;
  }
  device.clearRefusal();
  // Room is checked before anything is sent, with the numbers the device has now.
  await device.refresh();
  if (device.shortBy(file) > 0) {
    if (!context.mounted) return;
    await confirmDownload(
      context,
      title: 'Add ${file.name}?',
      lines: [DownloadLine(file.name, file.size)],
      space: device.spaceForDialog,
      name: file.name,
      footnote: 'Nothing was uploaded.',
    );
    return;
  }
  say('Uploading ${file.name}. Keep this tab open.');
  final result = await device.send(file);
  if (result == null || kindOfFileName(file.name) != 'library' || libraries == null) return;
  if (!context.mounted) return;
  await addPackageOnDevice(context, libraries, file.name);
}

/// Adds the library package that waits on the device as `incoming/<name>`, asking what a phone asks (an update of a library that is
/// already here, a settings file the app cannot work out).
Future<void> addPackageOnDevice(BuildContext context, LibrariesState libraries, String name) =>
    libraries.addDeviceFile(
      name,
      confirmUpdate: (n, from, to) => askUpdateLibrary(context, n, from, to),
      askSettings: (reason) => askLibrarySettings(context, reason, libraries.pickSettingsOnDevice),
    );
