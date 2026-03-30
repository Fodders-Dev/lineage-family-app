import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<String> _loadVersionLabel() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return 'Версия ${packageInfo.version} (сборка ${packageInfo.buildNumber})';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 24),
            Icon(
              Icons.family_restroom,
              size: 120,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(height: 24),
            const Text(
              'Родня',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            FutureBuilder<String>(
              future: _loadVersionLabel(),
              builder: (context, snapshot) {
                final versionLabel = snapshot.data ?? 'Версия загружается...';
                return Text(
                  versionLabel,
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                );
              },
            ),
            const SizedBox(height: 32),
            const Text(
              'Родня - это приложение для создания и хранения семейного древа, которое помогает сохранить историю семьи и поддерживать связь с близкими.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.5),
            ),
            const SizedBox(height: 32),
            const ListTile(
              title: Text('Разработчики'),
              subtitle: Text('Artem Kuznetsov'),
              leading: Icon(Icons.code),
            ),
            const ListTile(
              title: Text('Политика конфиденциальности'),
              leading: Icon(Icons.privacy_tip),
            ),
            const ListTile(
              title: Text('Условия использования'),
              leading: Icon(Icons.description),
            ),
            const SizedBox(height: 16),
            Text(
              '© 2026 Родня. Все права защищены.',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}
