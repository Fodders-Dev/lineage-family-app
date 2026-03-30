import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/widgets/offline_indicator.dart';

void main() {
  testWidgets(
    'OfflineIndicator stays hidden when SyncService is not registered',
    (tester) async {
      final getIt = GetIt.I;
      await getIt.reset();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfflineIndicator(),
          ),
        ),
      );

      expect(find.byType(OfflineIndicator), findsOneWidget);
      expect(find.text('Вы находитесь в офлайн-режиме'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    },
  );
}
