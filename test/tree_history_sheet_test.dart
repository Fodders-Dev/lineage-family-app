// TreeHistorySheet ("История изменений" — модальный лист) не имела ни
// одного теста, хотя это переиспользуемый виджет для 4 экранов
// (add_relative, profile, relative_details, tree_view). Конструктор
// берёт historyFuture напрямую (без GetIt), так что фейковый сервис не
// нужен — только Future<List<TreeChangeRecord>>. Пины: загрузка →
// список записей, пустое состояние (default + custom emptyMessage),
// ошибка (default + custom errorBuilder), фильтр-чипы сужают список,
// "Открыть карточку" вызывает onOpenPerson, отсутствие overflow на
// узком экране, тач-таргет иконки-кнопки в строке ≥44dp.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/models/tree_change_record.dart';
import 'package:rodnya/widgets/tree_history_sheet.dart';

TreeChangeRecord _record({
  required String id,
  required String type,
  String? actorId,
  String? personId,
}) {
  return TreeChangeRecord(
    id: id,
    treeId: 'tree-1',
    type: type,
    actorId: actorId,
    personId: personId,
    createdAt: DateTime(2026, 4, 3, 12, 30),
  );
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('загрузка → список из 3 записей журнала', (tester) async {
    final completer = Completer<List<TreeChangeRecord>>();
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: completer.future,
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));

    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Добавлен человек'), findsNothing);

    completer.complete([
      _record(id: 'r-1', type: 'person.created', actorId: 'user-1'),
      _record(id: 'r-2', type: 'relation.created', actorId: 'user-2'),
      _record(id: 'r-3', type: 'person_media.created', actorId: 'user-1'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('История изменений'), findsOneWidget);
    expect(find.text('Иван Иванов'), findsOneWidget);
    expect(find.text('Добавлен человек'), findsOneWidget);
    expect(find.text('Добавлена связь'), findsOneWidget);
    expect(find.text('Добавлено фото'), findsOneWidget);
  });

  testWidgets('пустой журнал — дефолтное сообщение', (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value(const <TreeChangeRecord>[]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Записей в журнале пока нет.'), findsOneWidget);
  });

  testWidgets('пустой журнал — кастомный emptyMessage от вызывающего экрана',
      (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value(const <TreeChangeRecord>[]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
      emptyMessage: 'Для этой карточки пока нет записей в журнале.',
    )));
    await tester.pumpAndSettle();

    expect(
      find.text('Для этой карточки пока нет записей в журнале.'),
      findsOneWidget,
    );
  });

  testWidgets('ошибка загрузки — дефолтное сообщение', (tester) async {
    // Завершаем completer ошибкой ПОСЛЕ pumpWidget, а не через
    // Future.error(...) в аргументе конструктора — иначе тестовая зона
    // видит непойманную ошибку раньше, чем FutureBuilder успевает на
    // неё подписаться (initState происходит уже после того, как
    // Future.error спланировал доставку).
    final completer = Completer<List<TreeChangeRecord>>();
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: completer.future,
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));
    completer.completeError(Exception('boom'));
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить историю.'), findsOneWidget);
  });

  testWidgets('ошибка загрузки — кастомный errorBuilder', (tester) async {
    final completer = Completer<List<TreeChangeRecord>>();
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: completer.future,
      title: 'История изменений',
      subtitle: 'Иван Иванов',
      errorBuilder: (error) => 'Кастомная ошибка: $error',
    )));
    completer.completeError(Exception('нет доступа'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Кастомная ошибка:'), findsOneWidget);
  });

  testWidgets('фильтр "Люди" сужает список до person.*', (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.created'),
        _record(id: 'r-2', type: 'relation.created'),
        _record(id: 'r-3', type: 'person_media.created'),
      ]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Добавлен человек'), findsOneWidget);
    expect(find.text('Добавлена связь'), findsOneWidget);
    expect(find.text('Добавлено фото'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Люди'));
    await tester.pumpAndSettle();

    expect(find.text('Добавлен человек'), findsOneWidget);
    expect(find.text('Добавлена связь'), findsNothing);
    expect(find.text('Добавлено фото'), findsNothing);
  });

  testWidgets('фильтр без совпадений — "Под выбранный фильтр записей пока нет."',
      (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.created'),
      ]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Связи'));
    await tester.pumpAndSettle();

    expect(
      find.text('Под выбранный фильтр записей пока нет.'),
      findsOneWidget,
    );
  });

  testWidgets('«Открыть карточку» вызывает onOpenPerson с id персоны',
      (tester) async {
    String? openedPersonId;
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.updated', personId: 'person-42'),
      ]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
      onOpenPerson: (personId) => openedPersonId = personId,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Открыть карточку'));
    await tester.pumpAndSettle();

    expect(openedPersonId, 'person-42');
  });

  testWidgets('без onOpenPerson кнопка "Открыть карточку" не рендерится',
      (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.updated', personId: 'person-42'),
      ]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
    )));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Открыть карточку'), findsNothing);
  });

  // НАХОДКА (не фиксится в этом тестовом чанке — только вёрстку/логику,
  // не трогаем production-код сверх минимальных швов): IconButton
  // «Открыть карточку» задаёт visualDensity: VisualDensity.compact —
  // baseSizeAdjustment компактной плотности −8dp на ось уменьшает
  // kMinInteractiveDimension (48dp) до фактических 40×40dp, ниже
  // рекомендованных 44dp. Restore/purge-кнопки в DeletedItemRow (трэш-
  // экраны) той же плотности НЕ задают и остаются на дефолтных 48dp —
  // см. соответствующий тест в trash_screen_test.dart. Тест ниже пинит
  // фактическое (нонкомплаентное) поведение, а не выдуманный порог.
  testWidgets('тач-таргет «Открыть карточку» — фактически 40×40dp (< 44dp, известный гэп)',
      (tester) async {
    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.updated', personId: 'person-42'),
      ]),
      title: 'История изменений',
      subtitle: 'Иван Иванов',
      onOpenPerson: (_) {},
    )));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.ancestor(
      of: find.byIcon(Icons.open_in_new),
      matching: find.byType(IconButton),
    ));
    expect(size, const Size(40, 40));
  });

  testWidgets('на узком экране 360×640 нет переполнения', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(TreeHistorySheet(
      historyFuture: Future.value([
        _record(id: 'r-1', type: 'person.created', personId: 'person-1'),
        _record(id: 'r-2', type: 'relation.updated', personId: 'person-2'),
      ]),
      title: 'История изменений',
      subtitle: 'Очень длинное имя владельца карточки для проверки переполнения',
      onOpenPerson: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
