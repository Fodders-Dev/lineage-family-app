import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/models/app_event.dart';

void main() {
  test('AppEvent.status formats upcoming short ranges with Russian declension',
      () {
    final now = DateTime.now();
    final event = AppEvent(
      id: 'birthday-1',
      type: AppEventType.birthday,
      date: DateTime(now.year, now.month, now.day).add(const Duration(days: 3)),
      title: 'День рождения',
      personName: 'Иван Петров',
      personId: 'person-1',
      icon: Icons.cake_outlined,
    );

    expect(event.status, 'Через 3 дня');
  });
}
