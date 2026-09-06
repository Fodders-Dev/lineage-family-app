// Density invariant (chunk 20 — карточка поста в ленте): the post
// header + text + action row must stay compact enough that a short
// text-only post (2 lines) fits in one glance, matching the ticket's
// «текстовый пост из 2 строк ≤ 150dp целиком» target. Promoted from a
// throwaway measurement probe used to compare before/after numbers
// while redesigning _buildPostHeader / the content Text / the media
// padding / _buildPostActions in lib/widgets/post_card.dart.
//
// Height budget note: [PostCard] returns a GlassPanel whose own margin
// (vertical 4/4 — the inter-card gap from the ticket's «зазор между
// карточками 8», a spacing concern separate from the card's own
// content stack) is baked into the render box Flutter reports for
// `find.byType(PostCard)`. The ≤150dp target is about the card's
// content (header/text/actions), so this test subtracts that fixed
// margin before asserting — see `_kCardVerticalMargin` below, which
// must track PostCard's GlassPanel margin.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/widgets/post_card.dart';

/// PostCard's GlassPanel `margin: EdgeInsets.symmetric(vertical: 4)` —
/// counted twice (top+bottom) because Container bakes margin into its
/// own render size when given loose constraints (as here, inside a
/// SingleChildScrollView). This is the inter-card gap, not part of the
/// card's own content — see the file doc comment above.
const double _kCardVerticalMargin = 8;

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';
  @override
  String? get currentUserEmail => 'user@example.com';
  @override
  String? get currentUserDisplayName => 'Тестовый пользователь';
  @override
  String? get currentUserPhotoUrl => null;
  @override
  List<String> get currentProviderIds => const ['password'];
  @override
  Stream<String?> get authStateChanges => const Stream.empty();
  @override
  String describeError(Object error) => error.toString();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePostService implements PostServiceInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Size> _pumpAndMeasure(WidgetTester tester, Post post) async {
  // 412×915dp phone canvas, dpr 3 — same reference size chunk 19's
  // home_feed_header_density_test.dart uses.
  tester.view.physicalSize = const Size(412 * 3, 915 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: PostCard(post: post)),
      ),
    ),
  );
  // Network images never resolve in tests (sit on the shimmer
  // placeholder, which animates forever) — pump a couple of frames
  // rather than pumpAndSettle, mirroring test/post_card_test.dart's
  // multi-photo carousel test.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  return tester.getSize(find.byType(PostCard));
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<PostServiceInterface>(_FakePostService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  // Calibrated so the post body wraps to exactly 2 lines under
  // flutter_test's substitute font metrics (no real Manrope loaded in
  // widget tests — see docs note in the PR/report). On a real device
  // with the real font this string renders as a single short line with
  // room to spare, so the invariant below is, if anything, pessimistic.
  const twoLineContent = 'Заходили к бабушке на даче, пекли пирог.';

  testWidgets(
    'PostCard (чанк 20): текстовый пост из 2 строк ≤150dp (без учёта '
    'зазора между карточками)',
    (tester) async {
      final size = await _pumpAndMeasure(
        tester,
        Post(
          id: 'post-1',
          treeId: 'tree-1',
          authorId: 'author-1',
          authorName: 'Анна',
          content: twoLineContent,
          createdAt: DateTime(2026, 4, 13, 10),
        ),
      );

      final contentHeight = size.height - _kCardVerticalMargin;
      expect(
        contentHeight,
        lessThanOrEqualTo(150),
        reason: 'Шапка (аватар+меню) + текст (2 строки) + строка действий '
            'не должны в сумме превышать 150dp — см. docs/DoD чанка 20. '
            'Замерено: card=${size.height}, margin=$_kCardVerticalMargin, '
            'content=$contentHeight.',
      );
    },
  );

  testWidgets(
    'PostCard (чанк 20): пост с одним фото — сама карточка (не считая '
    'медиа) держит тот же ≤150dp бюджет',
    (tester) async {
      final size = await _pumpAndMeasure(
        tester,
        Post(
          id: 'post-2',
          treeId: 'tree-1',
          authorId: 'author-1',
          authorName: 'Анна',
          content: twoLineContent,
          imageUrls: const ['https://example.com/photo.jpg'],
          createdAt: DateTime(2026, 4, 13, 10),
        ),
      );

      // Media block height including its own bottom gap to the next
      // element (FeedMediaGallery's `padding: EdgeInsets.only(bottom:
      // tokens.space8)` from _buildPostImages) — that gap is part of
      // the media block's own footprint, not «chrome».
      final mediaBox = tester.getSize(find.byType(AspectRatio).first);
      const mediaBottomGap = 8; // tokens.space8, see _buildPostImages.
      final mediaFootprint = mediaBox.height + mediaBottomGap;

      final chromeHeight = size.height - _kCardVerticalMargin - mediaFootprint;
      expect(
        chromeHeight,
        lessThanOrEqualTo(150),
        reason: 'Шапка+текст+строка действий вокруг фото не должны '
            'превышать тот же ≤150dp бюджет, что и текстовый пост — '
            'высота самого медиа (натуральная пропорция 16:9…4:5) не '
            'ограничена этим бюджетом отдельно. Замерено: '
            'card=${size.height}, media(incl. gap)=$mediaFootprint, '
            'chrome=$chromeHeight.',
      );
    },
  );
}
