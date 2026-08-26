/// Returns the correct Russian noun form for [count].
///
/// Example: `1 дерево`, `2 дерева`, `5 деревьев`.
String russianPluralForm(
  int count, {
  required String one,
  required String few,
  required String many,
}) {
  final absolute = count.abs();
  final mod10 = absolute % 10;
  final mod100 = absolute % 100;

  if (mod10 == 1 && mod100 != 11) {
    return one;
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return few;
  }
  return many;
}
