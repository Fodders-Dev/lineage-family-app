// BlockedUsersScreen ("Заблокированные пользователи") — не имела ни
// одного теста, хотя плотностные агенты уже переверстали строку списка
// (плоская ListTile + hairline-разделитель вместо карточек-с-отступом,
// см. комментарий в самом экране). Пины текущее поведение: загрузка →
// загруженный список, пустое состояние, ошибка + повтор, разблокировка
// убирает строку и показывает снек, отсутствие overflow на узком экране.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/safety_service_interface.dart';
import 'package:rodnya/models/user_block_record.dart';
import 'package:rodnya/screens/blocked_users_screen.dart';

class _FakeSafetyService implements SafetyServiceInterface {
  _FakeSafetyService({
    this.blocks = const <UserBlockRecord>[],
    this.error,
    this.completer,
  });

  List<UserBlockRecord> blocks;
  Object? error;
  Completer<List<UserBlockRecord>>? completer;
  int listCalls = 0;
  String? lastUnblockedId;

  @override
  Future<List<UserBlockRecord>> listBlockedUsers() {
    listCalls += 1;
    if (completer != null) {
      final pending = completer!;
      completer = null; // только первый вызов "висит", остальные — сразу.
      return pending.future;
    }
    if (error != null) return Future.error(error!);
    return Future.value(blocks);
  }

  @override
  Future<void> unblockUser(String blockId) async {
    lastUnblockedId = blockId;
    blocks = blocks.where((b) => b.id != blockId).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserBlockRecord _block({
  required String id,
  String name = 'Пётр Сидоров',
  String? reason,
}) {
  return UserBlockRecord.fromMap({
    'id': id,
    'blockedUserId': 'user-$id',
    'blockedUserDisplayName': name,
    'createdAt': '2026-05-01T10:00:00.000Z',
    'reason': reason,
  });
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpBlocked(
    WidgetTester tester,
    _FakeSafetyService service,
  ) async {
    getIt.registerSingleton<SafetyServiceInterface>(service);
    await tester.pumpWidget(const MaterialApp(home: BlockedUsersScreen()));
  }

  testWidgets('загрузка → список из 3 заблокированных', (tester) async {
    final completer = Completer<List<UserBlockRecord>>();
    final service = _FakeSafetyService(completer: completer);
    await pumpBlocked(tester, service);

    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Пётр Сидоров'), findsNothing);

    completer.complete([
      _block(id: 'b-1', name: 'Пётр Сидоров'),
      _block(id: 'b-2', name: 'Анна Кузнецова', reason: 'Спам'),
      _block(id: 'b-3', name: 'Игорь Волков'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Пётр Сидоров'), findsOneWidget);
    expect(find.text('Анна Кузнецова'), findsOneWidget);
    expect(find.text('Игорь Волков'), findsOneWidget);
    expect(find.textContaining('Причина: Спам'), findsOneWidget);
  });

  testWidgets('пустой список — заголовок и подсказка', (tester) async {
    final service = _FakeSafetyService(blocks: const <UserBlockRecord>[]);
    await pumpBlocked(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Сейчас здесь пусто'), findsOneWidget);
    expect(
      find.text(
        'Если вы заблокируете кого-то из личного чата, пользователь '
        'появится в этом списке и вы сможете снять блокировку позже.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ошибка загрузки — сообщение и «Повторить» вызывает сервис ещё раз',
      (tester) async {
    final service = _FakeSafetyService(error: Exception('offline'));
    await pumpBlocked(tester, service);
    await tester.pumpAndSettle();

    expect(
      find.text('Не удалось загрузить список блокировок'),
      findsOneWidget,
    );
    expect(find.text('Повторить'), findsOneWidget);
    expect(service.listCalls, 1);

    service.error = null;
    service.blocks = [_block(id: 'b-1', name: 'Восстановленный Пользователь')];
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(service.listCalls, 2);
    expect(find.text('Восстановленный Пользователь'), findsOneWidget);
  });

  testWidgets('разблокировать убирает строку и показывает снек', (tester) async {
    final service = _FakeSafetyService(
      blocks: [_block(id: 'b-1', name: 'Пётр Сидоров')],
    );
    await pumpBlocked(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Пётр Сидоров'), findsOneWidget);
    await tester.tap(find.text('Разблокировать'));
    await tester.pump();

    expect(service.lastUnblockedId, 'b-1');
    expect(find.text('Пётр Сидоров снова сможет писать вам'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('Пётр Сидоров'), findsNothing);
    expect(find.text('Сейчас здесь пусто'), findsOneWidget);
  });

  testWidgets('на узком экране 360×640 нет переполнения', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = _FakeSafetyService(
      blocks: [
        _block(
          id: 'b-1',
          name: 'Александра Константинопольская-Долгорукая',
          reason: 'Постоянные оскорбления в личных сообщениях и спам-рассылки',
        ),
        _block(id: 'b-2', name: 'Игорь Волков'),
      ],
    );
    await pumpBlocked(tester, service);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
