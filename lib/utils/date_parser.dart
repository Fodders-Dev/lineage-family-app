// ignore_for_file: avoid_dynamic_calls

DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  // Если где-то используется legacy Firebase Timestamp (из-за кэша Hive, который сохранил его как-то странно)
  try {
    if (value.runtimeType.toString() == 'Timestamp') {
      return value.toDate();
    }
  } catch (_) {}
  return null;
}

DateTime parseDateTimeRequired(dynamic value) {
  return parseDateTime(value) ?? DateTime.now();
}
