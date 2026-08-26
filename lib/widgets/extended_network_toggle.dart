import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/extended_network_controller.dart';

/// Phase 4 chunk 2 (PHASE-4-PROPOSAL.md §2.1 + DECISIONS.md 2026-05-12
/// Q8.A/Q8.C): AppBar segmented control для toggle'а между «Моё дерево»
/// и «Расширенная сеть».
///
/// Скрывается если backend service не implements capability mixin
/// (`controller.isCapable == false`) — graceful degradation на старом
/// сервере. Альтернативно: показывать disabled с tooltip'ом — не
/// делаем, чтобы юзер не видел «фантомный» control'а который не
/// работает.
///
/// In compact toolbars the segmented control competes with add/overflow
/// actions, so the parent switches this widget to one icon with a tooltip.
/// The full labels remain available wherever the toolbar has enough room.
class ExtendedNetworkToggle extends StatelessWidget {
  const ExtendedNetworkToggle({
    super.key,
    this.compact = false,
  });

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ExtendedNetworkController>();
    if (!controller.isCapable) {
      // Старый сервер либо stub'нутый service — toggle полностью
      // скрыт. UI tree_view_screen рендерит legacy view без upset'ов.
      return const SizedBox.shrink();
    }
    if (compact) {
      return _IconOnlyToggle(controller: controller);
    }
    return _SegmentedToggle(controller: controller);
  }
}

class _SegmentedToggle extends StatelessWidget {
  const _SegmentedToggle({required this.controller});

  final ExtendedNetworkController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SegmentedButton<ExtendedNetworkMode>(
        showSelectedIcon: false,
        segments: [
          for (final mode in ExtendedNetworkMode.values)
            ButtonSegment<ExtendedNetworkMode>(
              value: mode,
              label: Text(
                mode.russianLabel,
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
        selected: <ExtendedNetworkMode>{controller.mode},
        onSelectionChanged: (selection) {
          if (selection.isEmpty) return;
          controller.setMode(selection.first);
        },
      ),
    );
  }
}

class _IconOnlyToggle extends StatelessWidget {
  const _IconOnlyToggle({required this.controller});

  final ExtendedNetworkController controller;

  @override
  Widget build(BuildContext context) {
    final isExtended = controller.mode == ExtendedNetworkMode.extended;
    return IconButton(
      tooltip: isExtended
          ? 'Расширенная сеть. Тапнуть → переключиться на «Моё дерево»'
          : 'Моё дерево. Тапнуть → показать расширенную сеть',
      icon: Icon(
        isExtended ? Icons.hub_outlined : Icons.account_tree_outlined,
      ),
      onPressed: () => controller.setMode(
        isExtended ? ExtendedNetworkMode.mine : ExtendedNetworkMode.extended,
      ),
    );
  }
}
