import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart'; // Импортируем Provider
import 'package:share_plus/share_plus.dart';
import '../theme/app_theme.dart';
import '../models/family_person.dart';
import '../models/family_tree.dart';
import '../models/profile_contribution.dart';
import '../models/account_linking_status.dart';
import '../models/user_profile.dart';
import '../providers/tree_provider.dart'; // Импортируем TreeProvider
import 'dart:async'; // Для Future
import 'dart:ui';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../models/post.dart';
import '../models/story.dart';
import '../widgets/post_card.dart';
import '../widgets/post_card_shimmer.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/media_lightbox.dart';
import '../widgets/profile_redesign.dart';
import '../widgets/profile_edit_sheet.dart';
import '../widgets/sign_out_confirmation_dialog.dart';
import '../widgets/story_rail.dart';
import '../widgets/tree_history_sheet.dart';
import '../widgets/glass_panel.dart';
import 'package:image_picker/image_picker.dart';
import '../backend/backend_runtime_config.dart';
import '../services/app_status_service.dart';
import '../services/custom_api_post_service.dart';
import '../services/user_profile_cache.dart';
import '../services/posts_cache.dart';
import '../services/posts_refresh_coordinator.dart';
import '../utils/photo_url.dart';
import '../utils/relative_details_route.dart';
import '../utils/russian_plural.dart';
import '../utils/user_facing_error.dart';

part 'profile_screen_sections.dart';

String _getSafeDisplayName(UserProfile profile) {
  final rawDisplayName = profile.displayName.trim();

  // Если displayName пустой или равен "Профиль", используем альтернативные источники
  if (rawDisplayName.isEmpty || rawDisplayName == 'Профиль') {
    final parts = <String>[];
    final firstName = profile.firstName.trim();
    if (firstName.isNotEmpty) {
      parts.add(firstName);
    }

    final middleName = profile.middleName.trim();
    if (middleName.isNotEmpty) {
      parts.add(middleName);
    }

    final lastName = profile.lastName.trim();
    if (lastName.isNotEmpty) {
      parts.add(lastName);
    }

    if (parts.isNotEmpty) {
      return parts.join(' ');
    }

    final username = profile.username.trim();
    if (username.isNotEmpty) {
      return username;
    }

    final email = profile.email.trim();
    if (email.isNotEmpty) {
      return email;
    }
  } else {
    // Проверяем, является ли displayName мусорным
    bool looksBad(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return true;
      if (trimmed.length > 80) return true;

      final badWords = ['example.com', 'test123', 'codex', 'mcp', '2026'];
      for (final word in badWords) {
        if (trimmed.toLowerCase().contains(word)) return true;
      }

      final digitCount = RegExp(r'\d').allMatches(trimmed).length;
      if (digitCount >= 6) return true;

      return false;
    }

    if (!looksBad(rawDisplayName)) {
      return rawDisplayName;
    }
  }

  return 'Профиль';
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  final StoryServiceInterface _storyService = GetIt.I<StoryServiceInterface>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  // Cache-first hydrate: when both caches are registered we paint the
  // profile chrome (name / avatar / posts strip) from disk immediately
  // and progressively swap in fresh API data instead of blocking the
  // whole screen on a serial chain of `getUserProfile + getUserTrees +
  // getRelatives × N + getPosts + getPendingContributions + ...`.
  // User reported "профиль как-то долго загружается" — the empirical
  // wait was 1.5–3 s on a cold start because every roundtrip ladders
  // sequentially. The cache hop sidesteps the wait entirely on warm
  // launches.
  late final UserProfileCache? _userProfileCache =
      GetIt.I.isRegistered<UserProfileCache>()
          ? GetIt.I<UserProfileCache>()
          : null;
  late final PostsCache? _postsCache =
      GetIt.I.isRegistered<PostsCache>() ? GetIt.I<PostsCache>() : null;
  UserProfile? _userProfile;
  String? _currentUserId; // Храним ID текущего пользователя
  int _treeCount = 0;
  int _relativeCount = 0;
  int _postCount = 0;
  List<Post> _userPosts = [];
  List<Story> _userStories = [];
  List<ProfileContribution> _pendingContributions = [];
  FamilyPerson? _selectedTreePerson;
  AccountLinkingStatus? _accountLinkingStatus;
  bool _isLoading = true;
  bool _isLoadingContributions = false;
  String _errorMessage = '';
  bool _postsUnavailable = false;
  bool _isLoadingStories = false;
  bool _storiesUnavailable = false;
  String? _lastStoriesTreeId;

  TreeKind? _selectedTreeKind(BuildContext context) =>
      context.select<TreeProvider, TreeKind?>(
        (provider) => provider.selectedTreeKind,
      );

  bool _isFriendsTree(BuildContext context) =>
      _selectedTreeKind(context) == TreeKind.friends;

  String _graphStatLabel(BuildContext context, int count) =>
      _isFriendsTree(context)
          ? russianPluralForm(
              count,
              one: 'связь',
              few: 'связи',
              many: 'связей',
            )
          : russianPluralForm(
              count,
              one: 'родственник',
              few: 'родственника',
              many: 'родственников',
            );

  String _graphProfilesLabel(BuildContext context) =>
      _isFriendsTree(context) ? 'Карточки' : 'Профили';

  String _graphPostsTitle(BuildContext context) =>
      _isFriendsTree(context) ? 'Лента круга' : 'Посты';

  String _graphPostsEmptyMessage(BuildContext context) =>
      _isFriendsTree(context)
          ? 'Здесь появятся заметки и фото.'
          : 'Появятся после первой публикации.';

  String _graphSelectionHint(BuildContext context) => _isFriendsTree(context)
      ? 'Сначала выберите активный круг друзей на вкладке "Дерево" или "Родные"'
      : 'Сначала выберите активное дерево на вкладке "Дерево" или "Родные"';

  /// Tracks whether we've already auto-opened the edit sheet for the
  /// current `?edit=...` query param so the deep-link only fires once
  /// per visit. Cleared via `_clearEditQueryParam` after the sheet
  /// dismisses.
  bool _autoEditConsumed = false;

  /// Шаг 5 bulk-upload: composer закрывается ДО публикации, pop(true)
  /// больше не сигналит об успехе — «Мои записи» узнают о новом посте тем
  /// же каналом, что и лента (координатор дёргается очередью после ACK).
  /// Identity-stable, как у home_screen: unregister по identity.
  // ignore: prefer_function_declarations_over_variables
  late final Future<void> Function() _postsRefreshCallback =
      () => _loadUserData();

  @override
  void initState() {
    super.initState();
    PostsRefreshCoordinator.instance.register(_postsRefreshCallback);
    _loadUserData();
  }

  @override
  void dispose() {
    PostsRefreshCoordinator.instance.unregister(_postsRefreshCallback);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selectedTreeId = context.read<TreeProvider>().selectedTreeId;
    if (_currentUserId == null || _isLoading) {
      return;
    }
    if (_lastStoriesTreeId != selectedTreeId) {
      _lastStoriesTreeId = selectedTreeId;
      unawaited(
        _loadSelectedTreePerson(
          selectedTreeId: selectedTreeId,
          currentUserId: _currentUserId!,
        ),
      );
      unawaited(
        _loadStoriesForContext(
          selectedTreeId: selectedTreeId,
          currentUserId: _currentUserId!,
        ),
      );
    }
    _maybeHandleEditQueryParam();
  }

  /// Reads `?edit=1` (or `?edit=<step>` 0..3) from the route URI and
  /// pops the redesign edit sheet on the next frame. Used as the
  /// canonical entry point for the legacy `/profile/edit` deep link
  /// — the route now redirects to `/profile?edit=1` so external
  /// callers (auth flow, onboarding flow, push notifications) keep
  /// working without knowing about the new modal sheet.
  void _maybeHandleEditQueryParam() {
    if (_autoEditConsumed) return;
    if (_userProfile == null) return;
    // GoRouter may not be installed (e.g. in widget tests that mount
    // ProfileScreen under a bare MaterialApp). Treat absence as «no
    // edit query param» — the screen still works, the deep-link just
    // doesn't auto-open the sheet.
    String? raw;
    try {
      raw = GoRouterState.of(context).uri.queryParameters['edit'];
    } catch (_) {
      return;
    }
    if (raw == null || raw.isEmpty) return;
    _autoEditConsumed = true;
    final step = int.tryParse(raw)?.clamp(0, 3) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _openProfileEditSheet(initialStep: step);
      if (!mounted) return;
      // Clear the query param so back-navigation / deep-link
      // refreshes don't reopen the sheet.
      try {
        final routerState = GoRouterState.of(context);
        if (routerState.uri.queryParameters.containsKey('edit')) {
          context.go('/profile');
        }
      } catch (_) {
        // No GoRouter — nothing to clear.
      }
    });
  }

  Future<void> _signOut() async {
    // Ship Q3 (2026-05-26): confirmation gate ПЕРЕД destructive signOut.
    // UX audit 2026-05-25 Critical #1: «tapping Выйти immediately logged
    // out without confirmation, caused session loss during audit».
    final confirmed = await showSignOutConfirmationDialog(
      context,
      _authService,
    );
    if (!confirmed || !mounted) return;
    await _authService.signOut();
    if (GetIt.I.isRegistered<TreeProvider>()) {
      await GetIt.I<TreeProvider>().clearSelection();
    }
    if (mounted) {
      context.go('/login');
    }
  }

  Future<void> _loadUserData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _postsUnavailable = false;
      _storiesUnavailable = false;
      _selectedTreePerson = null;
      _pendingContributions = [];
      _isLoadingContributions = true;
    });

    try {
      final userId = _authService.currentUserId;
      if (userId == null) {
        throw Exception("Пользователь не авторизован");
      }
      _currentUserId = userId; // Сохраняем ID

      // ── Cache-first hydrate ────────────────────────────────────────
      // If we have a cached profile + posts blob, paint them now and
      // drop the spinner. The fresh API data will replace it below
      // when the network calls return; if the network is offline we
      // still have a useable screen.
      final cachedProfile = await _userProfileCache?.read(userId);
      // Prefix the user-id key so profile posts don't collide with the
      // home feed's per-tree posts in the shared posts_v1 Hive box.
      final cachedPostsKey = 'profile:$userId';
      final cachedPosts = await _postsCache?.read(cachedPostsKey);
      if (cachedProfile != null && mounted) {
        _userProfile = cachedProfile;
        if (cachedPosts != null && cachedPosts.isNotEmpty) {
          _userPosts = cachedPosts;
          _postCount = cachedPosts.length;
        }
        setState(() {
          _isLoading = false;
        });
      }

      // ── Parallel fetch ──────────────────────────────────────────────
      // Was a 7-step ladder (each call awaited the previous one to
      // finish). Most are independent — fan them out so the wall-clock
      // wait collapses to the slowest single call. The relative count
      // still depends on the tree list so it's chained inside its
      // future.
      Future<List<Post>> postsFuture() async {
        try {
          return await _postService.getPosts(authorId: userId);
        } on CustomApiPostException catch (error) {
          if (error.statusCode == 404) {
            _postsUnavailable = true;
            return const <Post>[];
          }
          rethrow;
        }
      }

      Future<List<ProfileContribution>> contributionsFuture() async {
        try {
          // Hard 8 s timeout. _isLoadingContributions is on the
          // hot path of the profile chrome; if the endpoint hangs
          // the badge spinner spins forever. Empty list on timeout
          // is the right fallback because contributions are
          // optional and the user can pull-to-refresh.
          return await _profileService.getPendingProfileContributions().timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              debugPrint(
                'Profile contributions request timed out — '
                'returning empty list.',
              );
              return const <ProfileContribution>[];
            },
          );
        } catch (error) {
          debugPrint('Не удалось загрузить предложения по профилю: $error');
          return const <ProfileContribution>[];
        }
      }

      Future<AccountLinkingStatus?> linkingFuture() async {
        try {
          // Same reasoning as contributions — small endpoint, must
          // not block the profile chrome forever. The underlying
          // Future is non-nullable, so we wrap the timeout in a
          // try/catch on TimeoutException rather than using the
          // onTimeout callback (which would have to return a real
          // AccountLinkingStatus instance).
          return await _profileService
              .getCurrentAccountLinkingStatus()
              .timeout(const Duration(seconds: 8));
        } on TimeoutException {
          debugPrint('Trusted-channel summary request timed out.');
          return null;
        } catch (error) {
          debugPrint('Не удалось загрузить trusted-channel summary: $error');
          return null;
        }
      }

      final treesFuture = _familyService.getUserTrees();
      final relativesFuture = treesFuture.then((trees) async {
        _treeCount = trees.length;
        return _loadRelativeCount(
          currentUserId: userId,
          trees: trees,
        );
      });

      // Run each independent piece in parallel. We capture the values
      // individually instead of via Future.wait<dynamic> to keep type
      // inference clean.
      final profileResult = _profileService.getUserProfile(userId);
      final postsResult = postsFuture();
      final contributionsResult = contributionsFuture();
      final linkingResult = linkingFuture();

      final fetchedProfile = await profileResult;
      _userPosts = await postsResult;
      _postCount = _userPosts.length;
      _pendingContributions = await contributionsResult;
      _accountLinkingStatus = await linkingResult;
      _relativeCount = await relativesFuture;

      _userProfile = fetchedProfile;
      if (_userProfile == null) {
        throw Exception("Профиль пользователя не найден");
      }

      // Persist fresh snapshots so the next cold start can paint
      // immediately. Best-effort — failures don't break the screen.
      unawaited(_userProfileCache?.write(_userProfile!));
      unawaited(_postsCache?.write(cachedPostsKey, _userPosts));

      if (!mounted) {
        return;
      }
      final selectedTreeId = context.read<TreeProvider>().selectedTreeId;
      _lastStoriesTreeId = selectedTreeId;
      // These two are independent of each other AND of the visible
      // chrome — kick them off as fire-and-forget so the profile
      // header can settle into its final state instantly. Each path
      // does its own setState when its data arrives.
      unawaited(
        _loadSelectedTreePerson(
          selectedTreeId: selectedTreeId,
          currentUserId: userId,
        ),
      );
      unawaited(
        _loadStoriesForContext(
          selectedTreeId: selectedTreeId,
          currentUserId: userId,
        ),
      );
      // Profile is now hydrated — if we arrived via /profile?edit=1
      // (the redirect target for legacy /profile/edit deep links),
      // pop the redesign edit sheet on the next frame.
      _maybeHandleEditQueryParam();
    } catch (e) {
      // Cache-first soft failure: if we already painted something
      // from disk, downgrade the error to a quiet log so the screen
      // doesn't flash an error overlay over data the user can see.
      final hasUsableCache = _userProfile != null;
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось загрузить профиль.',
      );
      if (mounted && !hasUsableCache) {
        setState(() {
          _errorMessage = describeUserFacingError(
            authService: _authService,
            error: e,
            fallbackMessage: _appStatusService.isOffline
                ? 'Нет соединения. Профиль обновится, когда интернет вернётся.'
                : 'Не удалось загрузить профиль.',
          );
        });
      }
      debugPrint('Ошибка при загрузке данных пользователя: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingContributions = false;
        });
      }
    }
  }

  Future<void> _copyProfileConnectionLink(Uri link) async {
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ссылка для связи скопирована')),
    );
  }

  Future<void> _shareProfileConnectionLink(Uri link) async {
    final displayName =
        _userProfile == null ? 'Я' : _getSafeDisplayName(_userProfile!).trim();
    await SharePlus.instance.share(
      ShareParams(
        text: '$displayName в Родне\n$link\n\n'
            'Откройте ссылку, чтобы перейти к поиску по профильному коду, invite или claim flow.',
      ),
    );
  }

  Uri? _buildProfileConnectionLink(String? treeId, String profileCode) {
    final normalizedTreeId = treeId?.trim() ?? '';
    final normalizedProfileCode = profileCode.trim().replaceFirst('@', '');
    if (normalizedTreeId.isEmpty || normalizedProfileCode.isEmpty) {
      return null;
    }

    final baseUri = Uri.parse(BackendRuntimeConfig.current.publicAppUrl);
    return baseUri.replace(
      fragment:
          '/relatives/find/$normalizedTreeId?profileCode=${Uri.encodeQueryComponent(normalizedProfileCode)}',
    );
  }

  Future<int> _loadRelativeCount({
    required String currentUserId,
    required List<FamilyTree> trees,
  }) async {
    if (trees.isEmpty) return 0;
    // Was a sequential for-loop — N trees → N serial roundtrips while
    // the user stares at a spinner. Fan them out in parallel; the
    // wall-clock wait collapses to the single slowest tree.
    final results = await Future.wait<List<FamilyPerson>>(
      trees.map((tree) async {
        try {
          return await _familyService.getRelatives(tree.id);
        } catch (e) {
          debugPrint('Ошибка при загрузке родственников для профиля: $e');
          return const <FamilyPerson>[];
        }
      }),
    );

    final relativeIds = <String>{};
    for (final relatives in results) {
      for (final person in relatives) {
        if (person.userId == currentUserId) {
          continue;
        }
        relativeIds.add(person.id);
      }
    }
    return relativeIds.length;
  }

  Future<void> _loadStoriesForContext({
    required String? selectedTreeId,
    required String currentUserId,
  }) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _isLoadingStories = true;
      _storiesUnavailable = false;
    });

    try {
      final stories = await _storyService.getStories(
        treeId: selectedTreeId,
        authorId: currentUserId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _userStories = stories;
        _isLoadingStories = false;
      });
    } catch (error) {
      debugPrint('Ошибка загрузки stories в профиле: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _userStories = [];
        _storiesUnavailable = true;
        _isLoadingStories = false;
      });
    }
  }

  Future<void> _loadSelectedTreePerson({
    required String? selectedTreeId,
    required String currentUserId,
  }) async {
    if (!mounted) {
      return;
    }

    if (selectedTreeId == null || selectedTreeId.isEmpty) {
      setState(() {
        _selectedTreePerson = null;
      });
      return;
    }

    try {
      final relatives = await _familyService.getRelatives(selectedTreeId);
      final person = relatives.cast<FamilyPerson?>().firstWhere(
            (candidate) => candidate?.userId == currentUserId,
            orElse: () => null,
          );

      if (!mounted) {
        return;
      }

      setState(() {
        _selectedTreePerson = person;
      });
    } catch (error) {
      debugPrint('Ошибка загрузки карточки пользователя в дереве: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedTreePerson = null;
      });
    }
  }

  void _showSelectedTreePersonGallery(FamilyPerson person) {
    // Profile Redesign: rebuild the inline gallery viewer on top of the
    // shared MediaLightbox (same one used by post feed + chat
    // attachments). Hands the user pinch-to-zoom, swipe-to-dismiss,
    // and the dark-scrim treatment the design calls for, instead of
    // the bespoke Dialog + PageView we used to roll here.
    final gallery = person.photoGallery;
    if (gallery.isEmpty) return;

    final items = <MediaLightboxItem>[];
    for (var i = 0; i < gallery.length; i++) {
      final entry = gallery[i];
      final url = entry['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      final captionRaw = entry['caption']?.toString().trim() ?? '';
      final isPrimary = entry['isPrimary'] == true;
      final positionLabel = '${i + 1} / ${gallery.length}';
      final caption = [
        if (isPrimary) 'Основное фото',
        if (captionRaw.isNotEmpty) captionRaw,
        positionLabel,
      ].join(' · ');
      items.add(MediaLightboxItem(
        imageUrl: normalizePhotoUrl(url) ?? url,
        caption: caption.isEmpty ? null : caption,
      ));
    }
    if (items.isEmpty) return;
    MediaLightbox.show(context, items: items);
  }

  Future<void> _showSelectedTreePersonHistory(FamilyPerson person) async {
    final treeProvider = context.read<TreeProvider>();
    final treeId = treeProvider.selectedTreeId;
    if (treeId == null || treeId.isEmpty) {
      return;
    }

    final historyFuture = _familyService.getTreeHistory(
      treeId: treeId,
      personId: person.id,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return TreeHistorySheet(
          historyFuture: historyFuture,
          title: 'История изменений',
          subtitle: person.displayName,
          currentUserId: _authService.currentUserId,
          emptyMessage: 'Для этой карточки пока нет записей в журнале.',
          errorBuilder: (error) => describeUserFacingError(
            authService: _authService,
            error: error,
            fallbackMessage: 'Не удалось загрузить историю изменений.',
          ),
          onOpenPerson: (personId) {
            Navigator.of(sheetContext).pop();
            if (!mounted) {
              return;
            }
            context.push(relativeDetailsRoute(personId, treeId: treeId));
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final treeProvider = Provider.of<TreeProvider>(context);
    final selectedTreeId = treeProvider.selectedTreeId;
    final selectedTreeKind = treeProvider.selectedTreeKind;
    final selectedTreeName = treeProvider.selectedTreeName;
    final isFriendsTree = selectedTreeKind == TreeKind.friends;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
        child: _buildProfileTopbar(theme: theme, tokens: tokens),
      ),
      body: _isLoading
          ? _buildProfileStateCard(
              icon: Icons.person_search_outlined,
              title: 'Собираем профиль',
              message: 'Загружаем профиль.',
              showProgress: true,
            )
          : _errorMessage.isNotEmpty
              ? _buildProfileStateCard(
                  icon: _appStatusService.isOffline
                      ? Icons.cloud_off_outlined
                      : Icons.person_outline_rounded,
                  title: _appStatusService.isOffline
                      ? 'Нет соединения'
                      : 'Профиль временно недоступен',
                  message: _errorMessage,
                  actions: [
                    FilledButton.icon(
                      onPressed: () {
                        _appStatusService.requestRetry();
                        unawaited(_loadUserData());
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Повторить'),
                    ),
                  ],
                )
              : _userProfile == null ||
                      _currentUserId == null // Проверяем и userId
                  ? _buildProfileStateCard(
                      icon: Icons.person_off_outlined,
                      title: 'Профиль не собрался',
                      message:
                          'Не удалось получить досье пользователя. Попробуйте обновить экран ещё раз.',
                      actions: [
                        FilledButton.icon(
                          onPressed: () {
                            _appStatusService.requestRetry();
                            unawaited(_loadUserData());
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Повторить'),
                        ),
                      ],
                    )
                  : RefreshIndicator(
                      onRefresh: _loadUserData,
                      // Wide layout (>= 1180): Stack with the main
                      // CustomScrollView padded on the right + a
                      // floating sidebar holding tree-card / completion
                      // meter / stories rail / connection card. Narrow
                      // keeps everything in a single capped column.
                      child: _buildProfileBody(
                        theme: theme,
                        scheme: scheme,
                        tokens: tokens,
                        selectedTreeId: selectedTreeId,
                        selectedTreeName: selectedTreeName,
                        isFriendsTree: isFriendsTree,
                      ),
                    ),
    );
  }

  Widget _buildProfileBody({
    required ThemeData theme,
    required ColorScheme scheme,
    required RodnyaDesignTokens tokens,
    required String? selectedTreeId,
    required String? selectedTreeName,
    required bool isFriendsTree,
  }) {
    final isWide = MediaQuery.of(context).size.width >= 1180;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 1180 : 760),
        child: Stack(
          children: [
            Padding(
              // On wide we leave 340dp on the right for the sidebar
              // overlay below. Sidebar is positioned with a 16dp
              // gutter — the offset stays in sync with that.
              padding: EdgeInsets.only(right: isWide ? 356 : 0),
              child: CustomScrollView(
                slivers: _buildProfileSlivers(
                  theme: theme,
                  scheme: scheme,
                  tokens: tokens,
                  isWide: isWide,
                  selectedTreeId: selectedTreeId,
                  selectedTreeName: selectedTreeName,
                  isFriendsTree: isFriendsTree,
                ),
              ),
            ),
            if (isWide)
              Positioned(
                top: 16,
                right: 0,
                bottom: 0,
                width: 340,
                // Visible-on-scroll Scrollbar so when sidebar overflow
                // happens (long tree-card / connection block / archive
                // rail) the user has a visual handle on it. Without
                // this the sidebar silently clipped at the bottom and
                // felt broken on the wide layout.
                child: Scrollbar(
                  thumbVisibility: false,
                  child: SingleChildScrollView(
                    primary: false,
                    physics: const ClampingScrollPhysics(),
                    child: _buildProfileSidebarColumn(
                      theme: theme,
                      scheme: scheme,
                      tokens: tokens,
                      selectedTreeId: selectedTreeId,
                      selectedTreeName: selectedTreeName,
                      isFriendsTree: isFriendsTree,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildProfileSlivers({
    required ThemeData theme,
    required ColorScheme scheme,
    required RodnyaDesignTokens tokens,
    required bool isWide,
    required String? selectedTreeId,
    required String? selectedTreeName,
    required bool isFriendsTree,
  }) {
    return [
      // Redesign hero card — cover gradient + avatar
      // overlap + name split + stats + pill actions.
      // Replaces the legacy PersonDossierView block;
      // matches docs/design_handoff/Profile Redesign.html.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ProfileHeroCard(
                fullName: _getSafeDisplayName(_userProfile!),
                firstName: _userProfile!.firstName.trim(),
                patronymic: _userProfile!.middleName.trim(),
                lastName: _userProfile!.lastName.trim(),
                photoUrl: _userProfile!.photoURL,
                coverPhotoUrl: _userProfile!.coverPhotoURL,
                location: _composeProfileLocation(_userProfile!),
                bio: _userProfile!.bio,
                stats: [
                  ProfileHeroStat(
                    value: '$_postCount',
                    label: russianPluralForm(
                      _postCount,
                      one: 'пост',
                      few: 'поста',
                      many: 'постов',
                    ),
                  ),
                  ProfileHeroStat(
                    value: '$_relativeCount',
                    label: _graphStatLabel(context, _relativeCount),
                  ),
                  ProfileHeroStat(
                    value: '$_treeCount',
                    label: russianPluralForm(
                      _treeCount,
                      one: 'дерево',
                      few: 'дерева',
                      many: 'деревьев',
                    ),
                  ),
                ],
                actions: [
                  PillButton(
                    label: 'Открыть дерево',
                    icon: Icons.account_tree_outlined,
                    onPressed: () {
                      if (selectedTreeId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              _graphSelectionHint(context),
                            ),
                            action: SnackBarAction(
                              label: 'Выбрать',
                              onPressed: () => context.go('/tree'),
                            ),
                          ),
                        );
                      } else {
                        context.go('/tree');
                      }
                    },
                  ),
                  PillButton(
                    label: 'Поделиться',
                    icon: Icons.share_outlined,
                    variant: PillButtonVariant.outlined,
                    onPressed: _shareProfileLink,
                  ),
                ],
                onTapAvatar: _pickProfilePhoto,
                onTapCover: _pickCoverPhoto,
                onEditPressed: () => _openProfileEditSheet(),
              ),
            ),
          ),
        ),
      ),
      // Completion meter — replaces sidebar widget on
      // narrow + adds suggestion chips that jump into
      // the right step of the edit sheet.
      if (!isWide && _userProfile != null)
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ProfileCompletionMeterCard(
                percent: _profileCompletionPercent(_userProfile!),
                suggestions: _profileCompletionChips(
                  _userProfile!,
                ),
              ),
            ),
          ),
        ),
      // ── Redesign info-card sections ─────────────────
      if (_basicsSectionHasContent(_userProfile!))
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: _buildBasicsSection(_userProfile!),
            ),
          ),
        ),
      if (_eduSectionHasContent(_userProfile!))
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: _buildEduSection(_userProfile!),
            ),
          ),
        ),
      if (_aboutSectionHasContent(_userProfile!))
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: _buildAboutSection(_userProfile!),
            ),
          ),
        ),
      if (_worldviewSectionHasContent(_userProfile!))
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: _buildWorldviewSection(_userProfile!),
            ),
          ),
        ),
      // Quick «Карточки в дереве» entry — keeps the
      // legacy /profile/offline_profiles button
      // discoverable now that the dossier action row
      // has been replaced by hero pills.
      SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: PillButton(
                label: _graphProfilesLabel(context),
                icon: Icons.people_outline,
                variant: PillButtonVariant.outlined,
                onPressed: () {
                  if (selectedTreeId == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _graphSelectionHint(context),
                        ),
                        action: SnackBarAction(
                          label: 'Выбрать',
                          onPressed: () => context.go('/tree'),
                        ),
                      ),
                    );
                  } else {
                    context.push(
                      '/profile/offline_profiles',
                    );
                  }
                },
              ),
            ),
          ),
        ),
      ),
      // The next four sections move to the right
      // sidebar when we're in wide layout — they're
      // about *the user* (their tree slot, their
      // account, their completion progress, their
      // stories) rather than *their content*, so
      // they read better as a contextual rail
      // beside the posts feed.
      if (!isWide && _selectedTreePerson != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              0,
              16,
              0,
            ),
            child: _buildTreeCardCompact(
              context,
              person: _selectedTreePerson!,
              isFriendsTree: isFriendsTree,
            ),
          ),
        ),
      if (!isWide && _accountLinkingStatus != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              8,
              16,
              0,
            ),
            child: _buildAccountSettingsLink(scheme, theme),
          ),
        ),
      // The ProfileCompletionMeterCard already lives
      // inline with the hero (above), so nothing else
      // needs the legacy meter widget here.
      if (!isWide)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16.0,
              10.0,
              16.0,
              0,
            ),
            child: _buildStoriesRailSection(),
          ),
        ),
      if (!isWide && _profileCodeLabel() != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16.0,
              10.0,
              16.0,
              0,
            ),
            child: _buildProfileConnectionSection(
              selectedTreeId: selectedTreeId,
              selectedTreeName: selectedTreeName,
            ),
          ),
        ),
      // PersonDossierView is now at the top (hero section).
      // This duplicate is removed.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          16.0,
          12.0,
          16.0,
          0,
        ),
        sliver: SliverToBoxAdapter(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Предложения от семьи',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
      ),
      if (_isLoadingContributions)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              12,
              16,
              0,
            ),
            child: _buildProfileStateCard(
              icon: Icons.edit_note_outlined,
              title: 'Проверяем семейные правки',
              message:
                  'Смотрим, не прислали ли родственники новые предложения по вашему профилю.',
              showProgress: true,
            ),
          ),
        )
      else if (_pendingContributions.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              12,
              16,
              0,
            ),
            child: _buildContributionEmptyState(),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            16,
            12,
            16,
            0,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                final contribution = _pendingContributions[index];
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index == _pendingContributions.length - 1 ? 0 : 10,
                  ),
                  child: _buildContributionCard(contribution),
                );
              },
              childCount: _pendingContributions.length,
            ),
          ),
        ),
      SliverPadding(
        // Было 24dp сверху — заметно больше соседних заголовков секций
        // (16 у «Предложений от семьи»), хотя раздел того же ранга.
        padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 6.0),
        sliver: SliverToBoxAdapter(
          child: Text(
            _graphPostsTitle(context),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ),
      if (_isLoading && _userPosts.isEmpty)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => const PostCardShimmer(),
            childCount: 2,
          ),
        )
      else if (_userPosts.isEmpty)
        SliverToBoxAdapter(
          child: EmptyStateWidget(
            icon: Icons.post_add_outlined,
            title: _postsUnavailable ? 'Посты недоступны' : 'Постов нет',
            message: _postsUnavailable
                ? 'Попробуйте позже.'
                : _graphPostsEmptyMessage(context),
            actionLabel: _postsUnavailable ? 'Обновить' : 'Создать',
            onAction: () async {
              if (_postsUnavailable) {
                _loadUserData();
                return;
              }
              final result = await context.push('/post/create');
              if (result == true) {
                _loadUserData();
              }
            },
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              return PostCard(
                post: _userPosts[index],
                onDeleted: () => _loadUserData(),
              );
            },
            childCount: _userPosts.length,
          ),
        ),
      // Profile Redesign: prominent «Выйти из аккаунта» button at the
      // tail of the profile, matching the design's warm-tinted ghost
      // button. The popup menu keeps a duplicate entry so power users
      // can sign out from the topbar without scrolling.
      SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: _SignOutButton(onTap: _signOut),
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
            child: Text(
              'Родня',
              style: AppTheme.serif(
                color: tokens.inkMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
      // The app shell now reserves the navigation region itself.
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  /// Right-side sticky-feeling column used on the wide-layout profile.
  /// Content mirrors the slivers we hide from the main column on wide:
  /// tree-card → completion meter → stories rail → connection card.
  Widget _buildProfileSidebarColumn({
    required ThemeData theme,
    required ColorScheme scheme,
    required RodnyaDesignTokens tokens,
    required String? selectedTreeId,
    required String? selectedTreeName,
    required bool isFriendsTree,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Consistent 16dp rhythm between sidebar cards (was a mix of
          // 12 and varying gaps that made the column feel busy).
          if (_selectedTreePerson != null) ...[
            _buildTreeCardCompact(
              context,
              person: _selectedTreePerson!,
              isFriendsTree: isFriendsTree,
            ),
            const SizedBox(height: 16),
          ],
          if (_accountLinkingStatus != null) ...[
            _buildAccountSettingsLink(scheme, theme),
            const SizedBox(height: 16),
          ],
          if (_userProfile != null) ...[
            ProfileCompletionMeterCard(
              percent: _profileCompletionPercent(_userProfile!),
              suggestions: _profileCompletionChips(_userProfile!),
            ),
            const SizedBox(height: 16),
          ],
          _buildStoriesRailSection(),
          const SizedBox(height: 16),
          if (_profileCodeLabel() != null) ...[
            _buildProfileConnectionSection(
              selectedTreeId: selectedTreeId,
              selectedTreeName: selectedTreeName,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProfileTopbar({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
  }) {
    // Performance: BackdropFilter is the single biggest frame-time
    // hit on mid-range Android (Samsung S20 FE / Galaxy A-series).
    // Keep it on iOS / desktop where the GPU eats it for breakfast,
    // skip it on Android — the underlying surface bumps to ~96%
    // opacity so the visual delta is essentially imperceptible
    // while the per-frame cost drops sharply.
    final useBlur = defaultTargetPlatform != TargetPlatform.android;
    final body = Container(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(
          alpha: theme.brightness == Brightness.dark
              ? (useBlur ? 0.74 : 0.96)
              : (useBlur ? 0.78 : 0.97),
        ),
        border: Border(
          bottom: BorderSide(
            color: tokens.surfaceLine.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppTheme.topbarContentHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 3, 12, 3),
            child: Row(
              children: [
                if (Navigator.of(context).canPop())
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: tokens.ink),
                    tooltip: 'Назад',
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    },
                  )
                else
                  const SizedBox(width: 14),
                Text(
                  'Профиль',
                  style: AppTheme.serif(
                    color: tokens.ink,
                    fontSize: AppTheme.tabTitleFontSize,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.22,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: 'Меню',
                  onSelected: (value) {
                    switch (value) {
                      case 'archive':
                        context.push('/profile/stories/archive');
                        break;
                      case 'settings':
                        context.push('/profile/settings');
                        break;
                      case 'about':
                        context.push('/profile/about');
                        break;
                      case 'logout':
                        _signOut();
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'archive', child: Text('Архив историй')),
                    const PopupMenuItem(
                        value: 'settings', child: Text('Настройки')),
                    const PopupMenuItem(
                        value: 'about', child: Text('О приложении')),
                    const PopupMenuItem(value: 'logout', child: Text('Выйти')),
                  ],
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tokens.surfaceStrong,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: tokens.surfaceLine),
                    ),
                    child: Icon(
                      Icons.settings_outlined,
                      size: 19,
                      color: tokens.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!useBlur) return body;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: body,
      ),
    );
  }

  // ── Profile Redesign helpers ──────────────────────────────────────────────
  // The new hero card + sections + edit sheet all read from the same
  // UserProfile we already hold in `_userProfile`. These helpers package
  // up the small bits that the design needs but `UserProfile` doesn't
  // expose directly: a single-line city/country string, a completion
  // percent + suggestion chips, the section visibility helpers, and the
  // photo-pick / edit-sheet plumbing.

  String? _composeProfileLocation(UserProfile profile) {
    final city = profile.city?.trim() ?? '';
    final country = profile.country?.trim() ?? '';
    if (city.isEmpty && country.isEmpty) return null;
    if (city.isEmpty) return country;
    if (country.isEmpty) return city;
    return '$city · $country';
  }

  /// Roughly mirrors the legacy ProfileCompletionMeter scoring: each
  /// non-empty meaningful field counts towards the percentage. The
  /// design's progress bar isn't a precision instrument — close-enough
  /// is exactly the point.
  double _profileCompletionPercent(UserProfile profile) {
    int total = 0;
    int filled = 0;
    void check(bool ok) {
      total += 1;
      if (ok) filled += 1;
    }

    check(profile.firstName.trim().isNotEmpty);
    check(profile.lastName.trim().isNotEmpty);
    check(profile.photoURL != null && profile.photoURL!.trim().isNotEmpty);
    check(profile.bio.trim().isNotEmpty);
    check(profile.birthDate != null);
    check((profile.city ?? '').trim().isNotEmpty ||
        (profile.country ?? '').trim().isNotEmpty);
    check(profile.hometown.trim().isNotEmpty);
    check(profile.education.trim().isNotEmpty);
    check(profile.work.trim().isNotEmpty);
    check(profile.languages.trim().isNotEmpty);
    check(profile.interests.trim().isNotEmpty);
    check(profile.aboutFamily.trim().isNotEmpty);
    if (total == 0) return 0;
    return (filled / total) * 100.0;
  }

  /// Build `+ {field}` suggestion chips for any sufficiently-rare empty
  /// field. Tapping a chip jumps directly to the matching step in the
  /// edit sheet so the user doesn't hunt.
  List<ProfileCompletionChipData> _profileCompletionChips(
    UserProfile profile,
  ) {
    final chips = <ProfileCompletionChipData>[];
    if (profile.bio.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'обо мне',
        onTap: () => _openProfileEditSheet(initialStep: 0),
      ));
    }
    if ((profile.city ?? '').trim().isEmpty &&
        (profile.country ?? '').trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'город',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.work.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'работа',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.education.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'учёба',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.languages.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'языки',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.interests.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'интересы',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.aboutFamily.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'о семье',
        onTap: () => _openProfileEditSheet(initialStep: 1),
      ));
    }
    if (profile.coverPhotoURL == null ||
        profile.coverPhotoURL!.trim().isEmpty) {
      chips.add(ProfileCompletionChipData(
        label: 'обложка',
        onTap: _pickCoverPhoto,
      ));
    }
    return chips;
  }

  // ── Section helpers ───────────────────────────────────────────────────────

  bool _basicsSectionHasContent(UserProfile p) {
    return p.birthDate != null ||
        (p.city ?? '').trim().isNotEmpty ||
        (p.country ?? '').trim().isNotEmpty ||
        p.hometown.trim().isNotEmpty ||
        p.languages.trim().isNotEmpty;
  }

  Widget _buildBasicsSection(UserProfile p) {
    final rows = <Widget>[];
    if (p.birthDate != null) {
      rows.add(InfoRow(
        icon: Icons.cake_outlined,
        label: 'Дата рождения',
        value: _formatBirthDate(p.birthDate!),
        isFirst: rows.isEmpty,
      ));
    }
    final loc = _composeProfileLocation(p);
    if (loc != null) {
      rows.add(InfoRow(
        icon: Icons.place_outlined,
        label: 'Город',
        value: loc,
        isFirst: rows.isEmpty,
      ));
    }
    if (p.hometown.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.account_tree_outlined,
        label: 'Родом из',
        value: p.hometown.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (p.languages.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.language_outlined,
        label: 'Языки',
        value: p.languages.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (rows.isNotEmpty) {
      // Mark the last row so it doesn't draw the bottom divider.
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        isFirst: last.isFirst,
        isLast: true,
      ));
    }
    return ProfileSection(title: 'Основное', children: rows);
  }

  bool _eduSectionHasContent(UserProfile p) {
    return p.education.trim().isNotEmpty || p.work.trim().isNotEmpty;
  }

  Widget _buildEduSection(UserProfile p) {
    final rows = <Widget>[];
    if (p.education.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.school_outlined,
        label: 'Образование',
        value: p.education.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (p.work.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.work_outline_rounded,
        label: 'Работа',
        value: p.work.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (rows.isNotEmpty) {
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        isFirst: last.isFirst,
        isLast: true,
      ));
    }
    return ProfileSection(title: 'Образование и работа', children: rows);
  }

  bool _aboutSectionHasContent(UserProfile p) {
    return p.familyStatus.trim().isNotEmpty ||
        p.aboutFamily.trim().isNotEmpty ||
        p.maidenName.trim().isNotEmpty;
  }

  Widget _buildAboutSection(UserProfile p) {
    final rows = <Widget>[];
    if (p.maidenName.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.label_outline,
        label: 'Девичья фамилия',
        value: p.maidenName.trim(),
        warm: true,
        isFirst: rows.isEmpty,
      ));
    }
    if (p.familyStatus.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.favorite_border_rounded,
        label: 'Семейное положение',
        value: p.familyStatus.trim(),
        warm: true,
        isFirst: rows.isEmpty,
      ));
    }
    if (p.aboutFamily.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.family_restroom_outlined,
        label: 'Заметка для семьи',
        value: p.aboutFamily.trim(),
        warm: true,
        isFirst: rows.isEmpty,
      ));
    }
    if (rows.isNotEmpty) {
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        warm: last.warm,
        isFirst: last.isFirst,
        isLast: true,
      ));
    }
    return ProfileSection(title: 'Семья', children: rows);
  }

  bool _worldviewSectionHasContent(UserProfile p) {
    return p.religion.trim().isNotEmpty || p.interests.trim().isNotEmpty;
  }

  Widget _buildWorldviewSection(UserProfile p) {
    final rows = <Widget>[];
    if (p.interests.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.auto_awesome_outlined,
        label: 'Интересы',
        value: p.interests.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (p.religion.trim().isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.book_outlined,
        label: 'Мировоззрение',
        value: p.religion.trim(),
        isFirst: rows.isEmpty,
      ));
    }
    if (rows.isNotEmpty) {
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        isFirst: last.isFirst,
        isLast: true,
      ));
    }
    return ProfileSection(title: 'Кругозор', children: rows);
  }

  String _formatBirthDate(DateTime d) {
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  // ── Edit sheet plumbing ──────────────────────────────────────────────────

  ProfileEditDraft _buildDraftFromProfile(UserProfile p) {
    String mapStoredScopeToDesignScope(String? stored) {
      // Backend canonical values differ from the design's vocabulary. The
      // edit sheet uses «private/family/public» labels but the backend
      // stores «private/shared_trees/public». Map both ways.
      switch ((stored ?? '').trim()) {
        case 'private':
          return 'private';
        case 'public':
          return 'public';
        case 'shared_trees':
        case 'specific_trees':
        case 'specific_branches':
        case 'specific_users':
        default:
          return 'family';
      }
    }

    final scopes = p.profileVisibilityScopes ?? const <String, String>{};
    return ProfileEditDraft(
      firstName: p.firstName,
      lastName: p.lastName,
      patronymic: p.middleName,
      gender: p.gender ?? Gender.unknown,
      maidenName: p.maidenName,
      bio: p.bio,
      birthDate: p.birthDate,
      city: p.city ?? '',
      country: p.country ?? '',
      hometown: p.hometown,
      education: p.education,
      work: p.work,
      languages: p.languages,
      religion: p.religion,
      interests: p.interests,
      familyNote: p.aboutFamily,
      bioVisibility: mapStoredScopeToDesignScope(scopes['about']),
      contactsVisibility: mapStoredScopeToDesignScope(scopes['contacts']),
      backgroundVisibility: mapStoredScopeToDesignScope(scopes['background']),
      allowsContributions: p.profileContributionPolicy == 'suggestions',
      photoUrl: p.photoURL,
      coverPhotoUrl: p.coverPhotoURL,
    );
  }

  Future<void> _openProfileEditSheet({int initialStep = 0}) async {
    final profile = _userProfile;
    if (profile == null) return;
    final draft = _buildDraftFromProfile(profile);
    final next = await showProfileEditSheet(
      context,
      initial: draft,
      isSelf: true,
      initialStep: initialStep,
      onPickPhoto: () async {
        final url = await _pickProfilePhoto();
        return url;
      },
      onPickCoverPhoto: () async {
        final url = await _pickCoverPhoto();
        return url;
      },
    );
    if (next == null || !mounted) return;
    await _persistProfileDraft(profile, next);
    if (mounted) {
      unawaited(_loadUserData());
    }
  }

  Future<void> _persistProfileDraft(
    UserProfile previous,
    ProfileEditDraft draft,
  ) async {
    String mapDesignScopeToStored(String design) {
      switch (design) {
        case 'private':
          return 'private';
        case 'public':
          return 'public';
        case 'family':
        default:
          return 'shared_trees';
      }
    }

    final scopes = Map<String, String>.from(
      previous.profileVisibilityScopes ?? const <String, String>{},
    );
    scopes['about'] = mapDesignScopeToStored(draft.bioVisibility);
    scopes['contacts'] = mapDesignScopeToStored(draft.contactsVisibility);
    scopes['background'] = mapDesignScopeToStored(draft.backgroundVisibility);
    if (!scopes.containsKey('worldview')) {
      scopes['worldview'] = mapDesignScopeToStored(draft.bioVisibility);
    }

    final updated = previous.copyWith(
      firstName: draft.firstName.trim(),
      lastName: draft.lastName.trim(),
      middleName: draft.patronymic.trim(),
      gender: draft.gender,
      maidenName: draft.maidenName.trim(),
      bio: draft.bio.trim(),
      birthDate: draft.birthDate,
      city: draft.city.trim(),
      country: draft.country.trim(),
      hometown: draft.hometown.trim(),
      education: draft.education.trim(),
      work: draft.work.trim(),
      languages: draft.languages.trim(),
      religion: draft.religion.trim(),
      interests: draft.interests.trim(),
      aboutFamily: draft.familyNote.trim(),
      profileContributionPolicy:
          draft.allowsContributions ? 'suggestions' : 'disabled',
      profileVisibilityScopes: scopes,
      photoURL: draft.photoUrl ?? previous.photoURL,
      coverPhotoURL: draft.coverPhotoUrl ?? previous.coverPhotoURL,
    );

    try {
      await _profileService.updateUserProfile(previous.id, updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Профиль обновлён')),
        );
      }
    } catch (error) {
      debugPrint('Не удалось сохранить профиль: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeUserFacingError(
                authService: _authService,
                error: error,
                fallbackMessage: 'Не удалось сохранить профиль.',
              ),
            ),
          ),
        );
      }
    }
  }

  /// Pick + upload a new avatar. Returns the new URL on success so the
  /// edit sheet can preview it without waiting for the next refresh.
  Future<String?> _pickProfilePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 2400,
      );
      if (picked == null) return null;
      final url = await _profileService.uploadProfilePhoto(picked);
      if (mounted) {
        final profile = _userProfile;
        if (url != null && url.trim().isNotEmpty && profile != null) {
          final updatedProfile = profile.copyWith(photoURL: url);
          setState(() {
            _userProfile = updatedProfile;
          });
          unawaited(_userProfileCache?.write(updatedProfile));
        }
        unawaited(_loadUserData());
      }
      return url;
    } catch (error) {
      debugPrint('Не удалось загрузить фото: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeUserFacingError(
                authService: _authService,
                error: error,
                fallbackMessage: 'Не удалось загрузить фото.',
              ),
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<String?> _pickCoverPhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 86,
        maxWidth: 2800,
      );
      if (picked == null) return null;
      final url = await _profileService.uploadCoverPhoto(picked);
      if (mounted) {
        final profile = _userProfile;
        if (url != null && url.trim().isNotEmpty && profile != null) {
          final updatedProfile = profile.copyWith(coverPhotoURL: url);
          setState(() {
            _userProfile = updatedProfile;
          });
          unawaited(_userProfileCache?.write(updatedProfile));
        }
        unawaited(_loadUserData());
      }
      return url;
    } catch (error) {
      debugPrint('Не удалось загрузить обложку: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeUserFacingError(
                authService: _authService,
                error: error,
                fallbackMessage: 'Не удалось загрузить обложку.',
              ),
            ),
          ),
        );
      }
      return null;
    }
  }

  void _shareProfileLink() {
    final profile = _userProfile;
    if (profile == null) return;
    final username = profile.username.trim();
    final fullName = _getSafeDisplayName(profile);
    final link = username.isNotEmpty
        ? 'https://rodnya-tree.ru/u/$username'
        : 'https://rodnya-tree.ru/u/${profile.id}';
    final body = 'Профиль $fullName в Родне\n$link';
    SharePlus.instance
        .share(ShareParams(text: body))
        .catchError((Object error) {
      debugPrint('Не удалось поделиться профилем: $error');
      return ShareResult('', ShareResultStatus.unavailable);
    });
  }
}

/// Bottom-of-profile sign-out button matching the design's warm
/// muted ghost treatment: full-width, surface-line border, warm-
/// coloured label, no fill until press. The popup-menu entry is the
/// secondary path (kept for power users), this is the primary one
/// the user expects to find on the profile screen.
class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tokens.surfaceLine),
          ),
          child: Center(
            child: Text(
              'Выйти из аккаунта',
              style: AppTheme.sans(
                color: tokens.warm,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
