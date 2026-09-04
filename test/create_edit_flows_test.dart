import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rodnya/models/media_upload_progress.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/circle_service_interface.dart';
import 'package:rodnya/models/audience_preset.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/backend/interfaces/profile_service_interface.dart';
import 'package:rodnya/backend/interfaces/story_service_interface.dart';
import 'package:rodnya/backend/models/profile_form_data.dart';
import 'package:rodnya/models/account_linking_status.dart';
import 'package:rodnya/models/circle.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/models/story.dart';
import 'package:rodnya/providers/theme_provider.dart';
import 'package:rodnya/providers/tree_provider.dart';
import 'package:rodnya/screens/create_post_screen.dart';
import 'package:rodnya/screens/create_story_screen.dart';
import 'package:rodnya/widgets/profile_edit_sheet.dart';
import 'package:rodnya/widgets/profile_redesign.dart';
import 'package:rodnya/screens/settings_screen.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/local_storage_service.dart';
import 'package:rodnya/services/rustore_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/services/post_publish_queue.dart';

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => [
        FamilyPerson(
          id: 'person-1',
          treeId: treeId,
          userId: 'user-2',
          name: 'Ирина Кузнецова',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2026, 4, 15),
          updatedAt: DateTime(2026, 4, 15),
        ),
      ];

  @override
  Future<List<FamilyTree>> getUserTrees() async => [
        FamilyTree(
          id: 'tree-1',
          name: 'Локальная семья',
          description: '',
          creatorId: 'user-1',
          memberIds: const ['user-1'],
          createdAt: DateTime(2026, 4, 15),
          updatedAt: DateTime(2026, 4, 15),
          isPrivate: true,
          members: const ['user-1'],
        ),
      ];

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async => [
        FamilyRelation(
          id: 'relation-1',
          treeId: treeId,
          person1Id: 'person-root',
          person2Id: 'person-1',
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2026, 4, 15),
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalStorageService implements LocalStorageService {
  @override
  Future<FamilyTree?> getTree(String treeId) async => FamilyTree(
        id: treeId,
        name: 'Локальная семья',
        description: '',
        creatorId: 'user-1',
        memberIds: const ['user-1'],
        createdAt: DateTime(2026, 4, 15),
        updatedAt: DateTime(2026, 4, 15),
        isPrivate: true,
        members: const ['user-1'],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePostService implements PostServiceInterface {
  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    String? clientRequestId,
    void Function(MediaUploadProgress progress)? onProgress,
  }) async =>
      Post(
        id: 'post-1',
        treeId: treeId,
        authorId: 'user-1',
        authorName: 'Codex',
        content: content,
        createdAt: DateTime(2026, 4, 15),
        isPublic: isPublic,
        circleId: circleId,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCircleService implements CircleServiceInterface {
  @override
  Future<AudiencePresetsResponse> getAudiencePresets(String treeId) async =>
      AudiencePresetsResponse.empty;

  @override
  Future<List<FamilyCircle>> getCircles(String treeId) async => [
        FamilyCircle(
          id: 'circle-all',
          treeId: treeId,
          kind: FamilyCircleKind.allTree,
          name: 'Всё дерево',
          isSystem: true,
          memberCount: 3,
          createdAt: DateTime(2026, 4, 15),
        ),
        FamilyCircle(
          id: 'circle-close',
          treeId: treeId,
          kind: FamilyCircleKind.custom,
          name: 'Близкие',
          isSystem: false,
          memberCount: 2,
          createdAt: DateTime(2026, 4, 15),
        ),
      ];
}

class _FakeStoryService implements StoryServiceInterface {
  @override
  Future<Story> createStory({
    required String treeId,
    required StoryType type,
    String? text,
    XFile? media,
    String? thumbnailUrl,
    DateTime? expiresAt,
    String? circleId,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const <String>[],
  }) async =>
      Story(
        id: 'story-1',
        treeId: treeId,
        authorId: 'user-1',
        authorName: 'Codex',
        type: type,
        text: text,
        mediaUrl: null,
        thumbnailUrl: thumbnailUrl,
        createdAt: DateTime(2026, 4, 15),
        expiresAt: DateTime(2026, 4, 16),
        circleId: circleId,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'codex@rodnya.dev';

  @override
  String? get currentUserDisplayName => 'Codex';

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  Stream<String?> get authStateChanges => const Stream<String?>.empty();

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  @override
  Future<AccountLinkingStatus> getCurrentAccountLinkingStatus() async =>
      const AccountLinkingStatus(
        summaryTitle: 'Аккаунт подтверждён через Telegram',
        summaryDetail: 'Основной канал: Telegram',
      );

  @override
  Future<ProfileFormData> getCurrentUserProfileFormData() async =>
      ProfileFormData(
        userId: 'user-1',
        email: 'codex@rodnya.dev',
        firstName: 'Кодекс',
        lastName: 'Локальный',
        middleName: '',
        displayName: 'Кодекс Локальный',
        username: 'codex',
        phoneNumber: '9991234567',
        countryCode: '7',
        countryName: 'Russia',
        city: 'Москва',
        gender: Gender.male,
        birthDate: DateTime(1990, 1, 1),
        bio: 'Люблю семейные истории',
        familyStatus: 'Женат',
        aboutFamily: 'Собираю рассказы старших родственников.',
        education: 'МГУ',
        work: 'Родня',
        hometown: 'Тверь',
        languages: 'Русский, английский',
        values: 'Семья',
        religion: 'Православие',
        interests: 'Генеалогия и путешествия',
        profileVisibilityScopes: const {
          'contacts': 'private',
          'about': 'shared_trees',
          'background': 'public',
          'worldview': 'shared_trees',
        },
      );

  @override
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data) async {}

  @override
  Future<String?> uploadProfilePhoto(XFile photo) async =>
      'https://example.com/a.jpg';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Шаг 5 bulk-upload: createPost, которым управляет тест — завершается
/// только по gate. Нужен, чтобы доказать: composer отпускает человека ДО
/// того, как публикация завершилась.
class _GatedPostService implements PostServiceInterface {
  final Completer<void> gate = Completer<void>();
  final List<String> contents = <String>[];

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    String? clientRequestId,
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    contents.add(content);
    await gate.future;
    return Post(
      id: 'post-${contents.length}',
      treeId: treeId,
      authorId: 'user-1',
      authorName: 'Автор',
      content: content,
      createdAt: DateTime(2026, 6, 1),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _withTree(Widget child) {
  final treeProvider = TreeProvider();
  treeProvider.selectTree('tree-1', 'Локальная семья');
  return ChangeNotifierProvider<TreeProvider>.value(
    value: treeProvider,
    child: MaterialApp(home: child),
  );
}

Widget _withTheme(Widget child) {
  return ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: MaterialApp(home: child),
  );
}

void main() {
  final getIt = GetIt.instance;
  const phoneNumberChannel = MethodChannel('com.julienvignali/phone_number');

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneNumberChannel, (call) async {
      if (call.method == 'validate') {
        return {'isValid': true};
      }
      return null;
    });
    await getIt.reset();
    PackageInfo.setMockInitialValues(
      appName: 'Rodnya',
      packageName: 'dev.rodnya.test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeFamilyTreeService());
    getIt.registerSingleton<PostServiceInterface>(_FakePostService());
    getIt.registerSingleton<CircleServiceInterface>(_FakeCircleService());
    getIt.registerSingleton<StoryServiceInterface>(_FakeStoryService());
    getIt.registerSingleton<LocalStorageService>(_FakeLocalStorageService());
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ProfileServiceInterface>(_FakeProfileService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
    getIt.registerSingleton<RustoreService>(RustoreService(
      reviewInitialize: () async {},
      reviewRequest: () async {},
      reviewShow: () async {},
    ));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneNumberChannel, null);
    await getIt.reset();
  });

  testWidgets('CreatePostScreen shows compact composer UI', (tester) async {
    await tester.pumpWidget(_withTree(const CreatePostScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Новый пост'), findsOneWidget);
    expect(find.text('О чём хотите рассказать родне?'), findsOneWidget);
    expect(find.text('Кому'), findsOneWidget);
    // The Photo button was renamed "Медиа" once the picker started
    // accepting video files alongside photos.
    expect(find.text('Медиа'), findsOneWidget);
    expect(find.text('Опубликовать'), findsOneWidget);
    expect(find.text('Всё дерево'), findsWidgets);
  });

  testWidgets('Q1: publish stays disabled until there is text or media',
      (tester) async {
    await tester.pumpWidget(_withTree(const CreatePostScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    InkWell publishButton() => tester.widget<InkWell>(
          find
              .ancestor(
                of: find.text('Опубликовать'),
                matching: find.byType(InkWell),
              )
              .first,
        );

    // Empty composer → the publish button has no tap handler (disabled).
    expect(publishButton().onTap, isNull);

    // Typing real content enables it.
    await tester.enterText(find.byType(TextField).first, 'Привет, родня!');
    await tester.pump();
    expect(publishButton().onTap, isNotNull);

    // Whitespace-only collapses back to empty → disabled again (trim check).
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();
    expect(publishButton().onTap, isNull);
  });

  testWidgets(
      'шаг 5: с очередью «Опубликовать» отпускает сразу — composer закрыт '
      'до завершения createPost, пост доходит в фоне', (tester) async {
    final gated = _GatedPostService();
    final queue = PostPublishQueue.memory(
        postService: gated, currentUserId: () => 'user-1');
    GetIt.I.registerSingleton<PostPublishQueue>(queue);
    addTearDown(() {
      queue.dispose();
      GetIt.I.unregister<PostPublishQueue>();
    });

    final treeProvider = TreeProvider();
    treeProvider.selectTree('tree-1', 'Локальная семья');
    final router = GoRouter(
      initialLocation: '/compose',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Лента')),
          routes: [
            GoRoute(
              path: 'compose',
              builder: (_, __) => const CreatePostScreen(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(ChangeNotifierProvider<TreeProvider>.value(
      value: treeProvider,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField).first, 'Фоновая запись');
    await tester.pump();
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    // Дать pop-анимации дожить (публикация всё ещё висит на gate).
    await tester.pump(const Duration(milliseconds: 600));

    // Composer закрыт, хотя createPost ещё не завершился.
    expect(find.text('Лента'), findsOneWidget);
    expect(find.byType(CreatePostScreen), findsNothing);
    expect(gated.contents, ['Фоновая запись'],
        reason: 'публикация стартовала в фоне');
    expect(queue.hasWork, isTrue);

    gated.gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    expect(queue.publishedCount, 1);
    expect(queue.items, isEmpty);
  });

  testWidgets(
      'шаг 5: двойной тап по «Опубликовать» = ОДИН пост '
      '(кнопка гаснет синхронно)', (tester) async {
    final gated = _GatedPostService();
    final queue = PostPublishQueue.memory(
        postService: gated, currentUserId: () => 'user-1');
    GetIt.I.registerSingleton<PostPublishQueue>(queue);
    addTearDown(() {
      queue.dispose();
      GetIt.I.unregister<PostPublishQueue>();
    });

    final treeProvider = TreeProvider();
    treeProvider.selectTree('tree-1', 'Локальная семья');
    final router = GoRouter(
      initialLocation: '/compose',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Лента')),
          routes: [
            GoRoute(
              path: 'compose',
              builder: (_, __) => const CreatePostScreen(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(ChangeNotifierProvider<TreeProvider>.value(
      value: treeProvider,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField).first, 'Один раз');
    await tester.pump();

    // Два тапа подряд, без pump между ними — как палец, дрогнувший на
    // кнопке. enqueue асинхронный, и без синхронного _isLoading-гварда
    // второй тап успевал создать второй пост.
    await tester.tap(find.text('Опубликовать'));
    await tester.tap(find.text('Опубликовать'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    gated.gate.complete();
    await tester.pump(const Duration(milliseconds: 50));

    expect(gated.contents, ['Один раз'],
        reason: 'двойной тап не должен публиковать дважды');
    expect(queue.publishedCount, 1);
  });

  testWidgets(
      'Q6: composer shows a compact audience summary, taxonomy behind «Изменить»',
      (tester) async {
    await tester.pumpWidget(_withTree(const CreatePostScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Default: a compact summary with «Изменить» + the current audience —
    // not the old chip strip.
    expect(find.byKey(const Key('compose-audience-summary')), findsOneWidget);
    expect(find.text('Изменить'), findsOneWidget);
    expect(find.text('Всё дерево'), findsWidgets);
    // The taxonomy is collapsed — the «Близкие» circle only appears once
    // the picker is opened.
    expect(find.text('Близкие'), findsNothing);

    // Tapping the summary opens the full picker sheet.
    await tester.tap(find.byKey(const Key('compose-audience-summary')));
    await tester.pumpAndSettle();
    expect(find.text('Кто увидит пост?'), findsOneWidget);
    expect(find.text('Близкие'), findsWidgets);
  });

  testWidgets('CreatePostScreen opens audience sheet and selects a circle',
      (tester) async {
    await tester.pumpWidget(_withTree(const CreatePostScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Кому'));
    await tester.pumpAndSettle();

    expect(find.text('Кто увидит пост?'), findsOneWidget);
    expect(find.text('По публичной ссылке'), findsOneWidget);
    expect(find.text('Отдельные ветки'), findsOneWidget);
    // The flat FilterChip Wrap was replaced by a compact summary
    // ("Выбрать людей") that opens a fullscreen multi-picker on
    // tap — virtualized so it scales to 200+ people. The chip with
    // "Ирина Кузнецова" only shows after opening that picker.
    expect(find.text('Выбрать людей'), findsOneWidget);

    await tester.tap(find.text('Близкие').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();

    expect(find.text('Близкие'), findsWidgets);
  });

  testWidgets('CreateStoryScreen shows compact story composer UI',
      (tester) async {
    await tester.pumpWidget(_withTree(const CreateStoryScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('История'), findsOneWidget);
    expect(find.text('24 часа'), findsWidgets);
    expect(find.text('Текст'), findsWidgets);
    expect(find.text('Превью'), findsOneWidget);
    expect(find.text('Формат'), findsOneWidget);
    expect(find.text('Поделитесь моментом'), findsOneWidget);
  });

  testWidgets('Profile Redesign edit sheet renders 4 named steps',
      (tester) async {
    // The legacy ProfileEditScreen has been retired in favour of
    // showProfileEditSheet — a 4-step bottom sheet («Кто я», «Жизнь»,
    // «Медиа», «Приватность») that ProfileScreen pops on edit. The
    // /profile/edit deep link now redirects to /profile?edit=1 which
    // triggers the same sheet. We assert the sheet's structure here so
    // any regression to the redesigned editing surface fails the build.
    await tester.pumpWidget(_withTheme(
      Builder(builder: (ctx) {
        return TextButton(
          onPressed: () => showProfileEditSheet(
            ctx,
            initial: const ProfileEditDraft(
              firstName: 'Анна',
              lastName: 'Кузнецова',
              patronymic: 'Сергеевна',
              bio: 'Хранитель семейного архива',
            ),
            isSelf: true,
          ),
          child: const Text('open-sheet'),
        );
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    // Sheet opens on step 0 («Кто я») — title shown in the header,
    // step indicator is `1 / 4`, and the step renders the redesign
    // input fields. _FieldGroup labels are uppercased per design.
    expect(find.text('Кто я'), findsWidgets);
    expect(find.text('1 / 4'), findsOneWidget);
    expect(find.text('ИМЯ'), findsWidgets);
    expect(find.text('ФАМИЛИЯ'), findsWidgets);
    expect(find.text('ОТЧЕСТВО'), findsWidgets);
  });

  testWidgets('Profile Redesign edit sheet exposes privacy scope buttons',
      (tester) async {
    await tester.pumpWidget(_withTheme(
      Builder(builder: (ctx) {
        return TextButton(
          onPressed: () => showProfileEditSheet(
            ctx,
            initial: const ProfileEditDraft(
              firstName: 'Анна',
              lastName: 'Кузнецова',
            ),
            isSelf: true,
            initialStep: 3,
          ),
          child: const Text('open-privacy'),
        );
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-privacy'));
    await tester.pumpAndSettle();

    // Step 3 («Приватность») uses PrivacyScopeRow buttons with the
    // canonical «Только я / Семья / Все» trio per content block.
    expect(find.byType(PrivacyScopeRow), findsWidgets);
    expect(find.text('Только я'), findsWidgets);
    expect(find.text('Семья'), findsWidgets);
    expect(find.text('Все'), findsWidgets);

    expect(find.text('← Назад'), findsOneWidget);
    await tester.tap(find.text('← Назад'));
    await tester.pumpAndSettle();

    expect(find.text('Медиа'), findsWidgets);
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('SettingsScreen shows compact settings sections', (tester) async {
    await tester.pumpWidget(_withTheme(const SettingsScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Плотность (чанк 9): убрали шапку-дублёр «Управление аккаунтом» —
    // экран и так называется «Настройки» в AppBar, а версия приложения
    // уже показана строкой ниже, в «О приложении». Проверяем, что обе
    // остались доступны из своих единственных мест.
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.textContaining('Версия 1.0.0'), findsOneWidget);
    expect(find.text('Внешний вид'), findsOneWidget);
    expect(find.text('Звонки'), findsOneWidget);
    expect(find.text('Микрофон по умолчанию'), findsOneWidget);
    expect(find.text('Мелодия входящего звонка'), findsOneWidget);
    expect(find.text('Документы и поддержка'), findsOneWidget);
    expect(find.text('Аккаунт'), findsOneWidget);
    expect(find.text('Удалить аккаунт'), findsOneWidget);
  });
}
