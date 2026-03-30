// Файл-заглушка, чтобы импорт условный работал на мобильных платформах
// Не содержит реальную функциональность
// Это временное решение для обхода проблем с idb_shim

class Database {}

class IdbFactory {}

class ObjectStore {}

class Transaction {}

class KeyRange {}

class Cursor {}

class CursorWithValue {}

class VersionChangeEvent {
  final Database database;
  VersionChangeEvent(this.database);
}

typedef OnUpgradeNeededFunction = void Function(VersionChangeEvent event);
typedef OnBlockedFunction = void Function(dynamic event);

enum DatabaseOpenMode { readonly, readwrite, versionchange }
