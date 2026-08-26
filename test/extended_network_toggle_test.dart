import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rodnya/backend/interfaces/extended_network_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/extended_network_slice.dart';
import 'package:rodnya/providers/extended_network_controller.dart';
import 'package:rodnya/widgets/extended_network_toggle.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeService implements ExtendedNetworkCapableFamilyTreeService {
  @override
  Future<ExtendedNetworkSlice?> getExtendedNetworkSlice({
    required String treeId,
    int maxHops = 4,
    bool includeAnonymous = true,
    List<String>? branchIds,
  }) async {
    return ExtendedNetworkSlice.empty;
  }
}

Widget _wrap(Widget child, {required Size screenSize}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: screenSize),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('ExtendedNetworkToggle: capable + wide → render SegmentedButton',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ExtendedNetworkController(
      treeId: 'tree-1',
      service: _FakeService(),
      preferences: prefs,
    );
    await controller.ready;

    await tester.pumpWidget(
      _wrap(
        ChangeNotifierProvider<ExtendedNetworkController>.value(
          value: controller,
          child: const ExtendedNetworkToggle(),
        ),
        screenSize: const Size(800, 600),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<ExtendedNetworkMode>), findsOneWidget);
    expect(find.text('Моё дерево'), findsOneWidget);
    expect(find.text('Все'), findsOneWidget);
  });

  testWidgets(
      'ExtendedNetworkToggle: incapable → SizedBox.shrink (полностью скрыт)',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ExtendedNetworkController(
      treeId: 'tree-1',
      service: null,
      preferences: prefs,
    );
    await controller.ready;

    await tester.pumpWidget(
      _wrap(
        ChangeNotifierProvider<ExtendedNetworkController>.value(
          value: controller,
          child: const ExtendedNetworkToggle(),
        ),
        screenSize: const Size(800, 600),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<ExtendedNetworkMode>), findsNothing);
    expect(find.text('Моё дерево'), findsNothing);
    expect(find.text('Все'), findsNothing);
  });

  testWidgets('ExtendedNetworkToggle: compact toolbar → IconButton fallback',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ExtendedNetworkController(
      treeId: 'tree-1',
      service: _FakeService(),
      preferences: prefs,
    );
    await controller.ready;

    await tester.pumpWidget(
      _wrap(
        ChangeNotifierProvider<ExtendedNetworkController>.value(
          value: controller,
          child: const ExtendedNetworkToggle(compact: true),
        ),
        screenSize: const Size(320, 600),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(SegmentedButton<ExtendedNetworkMode>), findsNothing);
  });

  testWidgets(
      'ExtendedNetworkToggle: tap «Все» переключает controller в extended',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ExtendedNetworkController(
      treeId: 'tree-1',
      service: _FakeService(),
      preferences: prefs,
    );
    await controller.ready;
    expect(controller.mode, ExtendedNetworkMode.mine);

    await tester.pumpWidget(
      _wrap(
        ChangeNotifierProvider<ExtendedNetworkController>.value(
          value: controller,
          child: const ExtendedNetworkToggle(),
        ),
        screenSize: const Size(800, 600),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Все'));
    await tester.pumpAndSettle();

    expect(controller.mode, ExtendedNetworkMode.extended);
  });

  testWidgets('ExtendedNetworkToggle: compact icon-only — tap toggle\'ит mode',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ExtendedNetworkController(
      treeId: 'tree-1',
      service: _FakeService(),
      preferences: prefs,
    );
    await controller.ready;
    expect(controller.mode, ExtendedNetworkMode.mine);

    await tester.pumpWidget(
      _wrap(
        ChangeNotifierProvider<ExtendedNetworkController>.value(
          value: controller,
          child: const ExtendedNetworkToggle(compact: true),
        ),
        screenSize: const Size(320, 600),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(controller.mode, ExtendedNetworkMode.extended);
  });
}
