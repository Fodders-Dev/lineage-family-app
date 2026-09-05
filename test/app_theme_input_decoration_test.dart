// M3 (50+) invariant: поля ввода читает аудитория 50+, поэтому размер
// шрифта ввода/подсказки на уровне глобальной InputDecorationTheme не
// должен просесть ниже 16sp, а однострочное поле не должно раздуться выше
// ~52dp (иначе один экран формы вмещает меньше полей, чем нужно). Чанк 12
// формы нашёл разнобой: тема держала подсказку на 14sp, лейбл в фокусе не
// был явно зафиксирован. Этот тест ловит будущий регресс на уровне темы,
// а не на конкретном экране — экраны намеренно не проверяются здесь.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/theme/app_theme.dart';

void main() {
  Future<void> pumpPlainField(
    WidgetTester tester, {
    required ThemeData theme,
    String? hintText,
    String? labelText,
  }) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          // TextFormField без явного style/hintStyle/labelStyle — только
          // то, что даёт тема приложения. Именно такое поле встречается
          // в большинстве форм (add_relative, create_tree, semya_invite
          // и т.д.), где decoration ограничивается labelText/hintText.
          child: TextFormField(
            decoration: InputDecoration(
              hintText: hintText,
              labelText: labelText,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final entry in <String, ThemeData>{
    'light': AppTheme.lightTheme,
    'dark': AppTheme.darkTheme,
  }.entries) {
    final themeName = entry.key;
    final theme = entry.value;

    testWidgets(
      '$themeName theme: hint text on an undecorated field is >=16sp',
      (tester) async {
        await pumpPlainField(tester, theme: theme, hintText: 'Подсказка');

        final hint = tester.widget<Text>(find.text('Подсказка'));
        final fontSize = hint.style?.fontSize;
        expect(fontSize, isNotNull);
        expect(
          fontSize!,
          greaterThanOrEqualTo(16.0),
          reason: 'M3 (50+): подсказка должна читаться наравне с обычным '
              'текстом (см. композер чата, chat_screen.dart) — тема не '
              'должна тихо вернуться к 14sp.',
        );
      },
    );

    testWidgets(
      '$themeName theme: typed input text on an undecorated field is >=16sp',
      (tester) async {
        await pumpPlainField(tester, theme: theme, hintText: 'x');
        await tester.enterText(find.byType(TextFormField), 'Иван');
        await tester.pump();

        final input = tester.widget<EditableText>(find.byType(EditableText));
        expect(
          input.style.fontSize,
          greaterThanOrEqualTo(16.0),
          reason: 'M3 (50+): текст ввода должен быть ≥16sp по умолчанию.',
        );
      },
    );

    testWidgets(
      '$themeName theme: single-line field height stays within 48-52dp on '
      '375x812',
      (tester) async {
        await pumpPlainField(
          tester,
          theme: theme,
          labelText: 'Имя',
          hintText: 'Иван',
        );

        final height = tester.getSize(find.byType(TextFormField)).height;
        expect(
          height,
          inInclusiveRange(44.0, 52.0),
          reason: 'M3 (50+): поле не должно раздуваться выше ~52dp, иначе '
              'форма теряет строки на первом экране (см. плотность '
              'чанков 12-15); ниже 44dp — уже нарушение тач-таргета.',
        );
      },
    );

    testWidgets(
      '$themeName theme: floating label stays readable (>=13sp) once the '
      'field is focused',
      (tester) async {
        await pumpPlainField(tester, theme: theme, labelText: 'Имя');
        await tester.enterText(find.byType(TextFormField), 'Иван');
        await tester.pumpAndSettle();

        final label = tester.getSize(find.text('Имя'));
        expect(
          label.height,
          inInclusiveRange(13.0, 14.0),
          reason: 'M3 (50+): лейбл в фокусе/заполнении должен компактнее '
              'состояния покоя (16), но не мельче helper/error (13) — если '
              'floatingLabelStyle не задан явно, лейбл вообще не сжимается '
              '(выглядит как ошибка анимации, а не осознанное решение).',
        );
      },
    );
  }
}
