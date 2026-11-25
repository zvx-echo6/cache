import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Red stub (to be replaced).
abstract class IdentityKeepStore {
  Future<String?> read();
  Future<void> write(String value);
}

class ChannelIdentityKeepStore implements IdentityKeepStore {
  const ChannelIdentityKeepStore({this.channel = const MethodChannel('co.cache/install_marker')});

  final MethodChannel channel;

  @override
  Future<String?> read() async => await channel.invokeMethod<String>('readIdentity');

  @override
  Future<void> write(String value) => channel.invokeMethod<void>('writeIdentity', {'value': value});
}

enum KeepState { kept, written, restored, missing, unknown, unreadable }

const String kKeyFile = 'identity.key';

String encodeKept(String installId, List<int> key) => jsonEncode({'install_id': installId, 'key': base64Encode(key)});

Future<KeepState> keepIdentity({required Directory syncDir, required String? installId, required IdentityKeepStore store}) async =>
    KeepState.missing;
