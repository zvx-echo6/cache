import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../brand.dart';
import '../layout/modules.dart';
import '../theme.dart';
import 'desktop.dart';
import 'desktop_theme.dart';

/// The frame of Cache on Linux in a window 1024 wide or more: a sidebar (232 wide from 1280, else a 72-pixel rail) with Home and
/// every module in the Modules screen's order, Settings pinned at the bottom, and the page beside it. The phone's pinned set is
/// ignored here. A tap goes to the destination; a right-click (or a press and hold) offers what the phone's long press does.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.child,
    required this.onHome,
    required this.onModule,
    required this.onModuleOptions,
    this.atHome = false,
    this.module,
    this.askOn = true,
    this.askDetail,
  });

  /// The page: the app's screens, or a picture's screen.
  final Widget child;

  final VoidCallback onHome;
  final void Function(ModuleId) onModule;

  /// Right-click or press and hold on a module: "Pin to bar" / "Unpin from bar" and "Add to Home".
  final void Function(BuildContext context, ModuleId module) onModuleOptions;

  /// Home is the page shown.
  final bool atHome;

  /// The module that is the page shown (null with [atHome] false: none is marked).
  final ModuleId? module;

  /// A chat model is on this device. Without one Ask is greyed and says [askDetail] ("Needs a model") under its name; a click still
  /// opens Ask's page, which explains.
  final bool askOn;
  final String? askDetail;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final wide = isLinuxWide(context);
    final full = wide && !_collapsed;
    final width = full ? DesktopMetrics.sidebarWidth : DesktopMetrics.railWidth;
    final modules = [for (final m in ModuleId.values) if (m != ModuleId.settings) m];
    Widget item({required Key key, required IconData icon, required IconData selectedIcon, required String label, required bool selected, required VoidCallback onTap, ModuleId? module, bool dim = false, String? detail}) {
      final color = selected ? k.accent : (dim ? k.secondary.withValues(alpha: 0.6) : k.secondary);
      final labelColor = selected ? k.accent : (dim ? k.secondary : k.text);
      final tile = Material(
        color: selected ? k.primary.withValues(alpha: 0.28) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: module == null ? null : () => widget.onModuleOptions(context, module),
          child: full
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(selected ? selectedIcon : icon, size: 22, color: color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: labelColor)),
                            if (detail != null) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(selected ? selectedIcon : icon, size: 24, color: color),
                      const SizedBox(height: 2),
                      Text(label, maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                    ],
                  ),
                ),
        ),
      );
      return Semantics(
        selected: selected,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: full ? 12 : 4, vertical: 2),
          // Right-click offers the same options as a press and hold.
          child: module == null
              ? tile
              : Listener(
                  onPointerDown: (e) {
                    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) widget.onModuleOptions(context, module);
                  },
                  child: tile,
                ),
        ),
      );
    }

    final sidebar = Container(
      key: const ValueKey('desktop-sidebar'),
      width: width,
      decoration: BoxDecoration(color: k.surface, border: Border(right: BorderSide(color: k.secondary.withValues(alpha: 0.2)))),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: DesktopMetrics.barHeight,
              child: full
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: InkWell(onTap: widget.onHome, child: const BrandWordmark(height: 24)),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  item(key: const ValueKey('desktop-nav-home'), icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home', selected: widget.atHome, onTap: widget.onHome),
                  for (final m in modules)
                    item(
                      key: ValueKey('desktop-nav-${m.name}'),
                      icon: m.icon,
                      selectedIcon: m.selectedIcon,
                      label: m.label,
                      selected: !widget.atHome && widget.module == m,
                      onTap: () => widget.onModule(m),
                      module: m,
                      dim: m == ModuleId.ask && !widget.askOn,
                      detail: m == ModuleId.ask && !widget.askOn ? widget.askDetail : null,
                    ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: k.secondary.withValues(alpha: 0.2)),
            const SizedBox(height: 4),
            item(
              key: const ValueKey('desktop-nav-settings'),
              icon: ModuleId.settings.icon,
              selectedIcon: ModuleId.settings.selectedIcon,
              label: ModuleId.settings.label,
              selected: !widget.atHome && widget.module == ModuleId.settings,
              onTap: () => widget.onModule(ModuleId.settings),
              module: ModuleId.settings,
            ),
            if (wide)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: full ? 12 : 4, vertical: 2),
                child: InkWell(
                  key: const ValueKey('desktop-nav-collapse'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _collapsed = !_collapsed),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      mainAxisAlignment: full ? MainAxisAlignment.start : MainAxisAlignment.center,
                      children: [
                        Icon(full ? Icons.keyboard_double_arrow_left : Icons.keyboard_double_arrow_right, size: 20, color: k.secondary),
                        if (full) ...[
                          const SizedBox(width: 12),
                          Text('Collapse', style: TextStyle(fontSize: 14, color: k.secondary)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    return Material(
      color: k.background,
      child: Row(
        children: [
          sidebar,
          // A snackbar sits at the bottom left of the page area, so it is told that area's width.
          Expanded(
            child: LayoutBuilder(builder: (context, c) => DesktopThemeScope(regionWidth: c.maxWidth, child: widget.child)),
          ),
        ],
      ),
    );
  }
}
