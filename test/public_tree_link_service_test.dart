import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/services/public_tree_link_service.dart';

void main() {
  test('builds hash-based public tree URL for Flutter web routing', () {
    final uri = PublicTreeLinkService.buildPublicTreeUri(
      'romanovs',
      publicAppUrl: 'http://127.0.0.1:7363',
    );

    expect(uri.toString(), 'http://127.0.0.1:7363/#/public/tree/romanovs');
  });

  test('appends public tree path to existing fragment prefix', () {
    final uri = PublicTreeLinkService.buildPublicTreeUri(
      'romanovs',
      publicAppUrl: 'http://127.0.0.1:7363/#/app',
    );

    expect(uri.toString(), 'http://127.0.0.1:7363/#/app/public/tree/romanovs');
  });
}
