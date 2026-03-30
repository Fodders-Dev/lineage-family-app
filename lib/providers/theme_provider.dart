import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  bool get isDarkMode => _themeMode == ThemeMode.dark;

  ThemeProvider() {
    _loadTheme();
  }

  // Загрузка сохраненной темы
  Future<void> _loadTheme() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String themeName = prefs.getString('theme_mode') ?? 'system';

    _themeMode = _getThemeFromString(themeName);
    notifyListeners();
  }

  // Преобразование строки в ThemeMode
  ThemeMode _getThemeFromString(String themeName) {
    switch (themeName) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  // Сохранение и установка темы
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();

    SharedPreferences prefs = await SharedPreferences.getInstance();
    String themeName = 'system';

    if (mode == ThemeMode.dark) {
      themeName = 'dark';
    } else if (mode == ThemeMode.light) {
      themeName = 'light';
    }

    await prefs.setString('theme_mode', themeName);
  }

  // Переключение между темной и светлой темой
  Future<void> toggleTheme() async {
    if (_themeMode == ThemeMode.dark) {
      await setThemeMode(ThemeMode.light);
    } else {
      await setThemeMode(ThemeMode.dark);
    }
  }

  ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: Colors.deepPurple,
      primarySwatch: Colors.deepPurple,
      colorScheme: ColorScheme.dark(
        primary: Colors.deepPurple,
        secondary: Colors.deepPurpleAccent,
        surface: Colors.grey[850]!,
        background: Colors.grey[900]!,
      ),
      scaffoldBackgroundColor: Colors.black,
      cardColor: Colors.grey[850],
      dividerColor: Colors.grey[800],
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: Colors.white),
        bodyLarge: TextStyle(color: Colors.white),
        titleLarge: TextStyle(color: Colors.white),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.black,
        selectedItemColor: Colors.deepPurpleAccent,
        unselectedItemColor: Colors.grey,
      ),
    );
  }
}
