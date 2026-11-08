import 'package:flutter/material.dart';

import '../../theme.dart';
import '../discover_state.dart';
import 'kit.dart';

/// Home's Discover card, in the Set up card's place once first run is done: one card that opens Discover, with how many updates
/// wait, and Hide (Edit Home brings it back).
class DiscoverCard extends StatelessWidget {
  const DiscoverCard({super.key, required this.discover, required this.onOpen, this.onHide});

  final DiscoverState discover;
  final VoidCallback onOpen;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: discover,
    builder: (context, _) {
      final k = context.t;
      final n = discover.updateCount;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          key: const ValueKey('discover-card'),
          color: k.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
              child: Row(
                children: [
                  DTile(discoverIcon('stack')),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Discover', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text(
                          n == 0 ? 'Activities, libraries and maps' : (n == 1 ? '1 update waiting' : '$n updates waiting'),
                          key: const ValueKey('discover-card-line'),
                          style: TextStyle(fontSize: 13, color: n == 0 ? k.secondary : k.accent),
                        ),
                      ],
                    ),
                  ),
                  if (onHide != null)
                    TextButton(
                      key: const ValueKey('discover-card-hide'),
                      onPressed: onHide,
                      style: TextButton.styleFrom(minimumSize: const Size(48, 40), padding: const EdgeInsets.symmetric(horizontal: 12)),
                      child: const Text('Hide'),
                    ),
                  Icon(Icons.chevron_right, color: k.secondary, size: 20),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
