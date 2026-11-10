import 'dart:convert';

import 'package:cache/app_state.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android loads the chat model file-backed in the mmap: no repack unless a measurement build asks for it', () {
    expect(kRepackChatWeightsForMeasurement, isFalse, reason: 'repacking is for measurement only, never in a released build');
    final options = jsonDecode(llamaLoadOptions(prefixDir: '/support/prompt-prefix')) as Map<String, dynamic>;
    expect(options, {'prefix_dir': '/support/prompt-prefix', 'repack_weights': false, 'preread_mbps': 0});
    expect(options.containsKey('mem_room_bytes'), isFalse, reason: 'free memory no longer chooses the weights mode');
  });

  test('the measurement opt-in and a missing prefix folder', () {
    expect(jsonDecode(llamaLoadOptions(repackWeights: true)), {'prefix_dir': '', 'repack_weights': true, 'preread_mbps': 0});
    expect(jsonDecode(llamaLoadOptions(prereadMbps: 40)), {'prefix_dir': '', 'repack_weights': false, 'preread_mbps': 40});
    expect(jsonDecode(llamaLoadOptions(prereadMbps: -5))['preread_mbps'], 0);
  });

  test('cl_info reports the mode and why', () {
    final info = ModelInfo.fromJson({
      'description': 'gemma',
      'n_ctx': 8192,
      'chat_format': 'x',
      'supports_tools': true,
      'weights': 'mmap',
      'weights_reason': 'default on Android',
    });
    expect('Model weights: ${info.weights} (${info.weightsReason ?? ''})', 'Model weights: mmap (default on Android)');
  });
}
