import 'package:flutter/material.dart';

class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    // В текущей версии Custom API офлайн-синхронизация пока не реализована.
    // Индикатор скрыт до появления новой реализации.
    return const SizedBox.shrink();
  }
}
