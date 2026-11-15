import 'package:flutter/material.dart';

import '../theme.dart';

/// The one-time card on the phone, at the top of Home the first time Cache is opened after a CarPlay connection (iPhone, only while
/// the microphone and speech recognition are not both allowed): it asks whether to allow voice search from the car. The words are
/// the owner's (2026-11-15). "Allow" brings up iOS's microphone and speech prompts (car_voice_access.dart); "Not now" and "Allow"
/// both put it away for good. Styled like the background-add notice card (FgsAddNoticeBody).
class CarVoiceCard extends StatelessWidget {
  const CarVoiceCard({super.key, required this.onAllow, required this.onNotNow});

  final VoidCallback onAllow;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      key: const ValueKey('car-voice-card'),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16), border: Border(left: BorderSide(color: k.accent, width: 4))),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.mic_none, size: 21, color: k.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Search by voice from the car?', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Tap the microphone on the car screen and say a place. Your words are turned into text on this iPhone.',
                        style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton(key: const ValueKey('car-voice-not-now'), onPressed: onNotNow, child: const Text('Not now')),
                FilledButton(key: const ValueKey('car-voice-allow'), onPressed: onAllow, child: const Text('Allow')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
