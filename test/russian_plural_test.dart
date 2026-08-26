import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/utils/russian_plural.dart';

void main() {
  test('russianPluralForm handles the main Russian number groups', () {
    String trees(int count) => russianPluralForm(
          count,
          one: 'дерево',
          few: 'дерева',
          many: 'деревьев',
        );

    expect(trees(0), 'деревьев');
    expect(trees(1), 'дерево');
    expect(trees(2), 'дерева');
    expect(trees(5), 'деревьев');
    expect(trees(11), 'деревьев');
    expect(trees(21), 'дерево');
    expect(trees(23), 'дерева');
    expect(trees(114), 'деревьев');
  });
}
