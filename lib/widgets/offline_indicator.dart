import 'package:flutter/material.dart';
// Возвращаем GetIt
import 'package:get_it/get_it.dart';
// Убираем Provider
// import 'package:provider/provider.dart';
import '../services/sync_service.dart';

class OfflineIndicator extends StatelessWidget {
  // Не инициализируем поле здесь
  // final syncService = GetIt.I<SyncService>();

  @override
  Widget build(BuildContext context) {
    if (!GetIt.I.isRegistered<SyncService>()) {
      return const SizedBox.shrink();
    }

    // Получаем SyncService через GetIt внутри метода build
    final syncService = GetIt.I<SyncService>();

    // Используем StreamBuilder, чтобы реагировать на изменения isOnline
    return StreamBuilder<bool>(
      stream: syncService
          .connectionStatusStream, // Используем стрим из GetIt-сервиса
      initialData: syncService.isOnline, // Начальное значение
      builder: (context, snapshot) {
        final bool isOnline =
            snapshot.data ?? true; // По умолчанию считаем онлайн

        if (isOnline) {
          return SizedBox.shrink(); // Не показываем ничего, если онлайн
        }

        // Показываем индикатор, если офлайн
        return Container(
          color: Colors.orangeAccent, // Чуть менее яркий цвет
          padding: EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off, size: 16, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Вы находитесь в офлайн-режиме',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ), // Уменьшим шрифт
              ),
            ],
          ),
        );
      },
    );
  }
}
