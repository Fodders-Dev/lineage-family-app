// ignore_for_file: library_private_types_in_public_api
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../providers/tree_provider.dart';
import '../services/event_service.dart';
import '../models/app_event.dart';
import '../models/family_connection_prompt.dart';
import '../models/family_tree.dart';

import '../widgets/battery_optimization_card.dart';
import '../widgets/event_card.dart';
import '../widgets/onboarding_resume_banner.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/identity_service_interface.dart';
import '../backend/models/tree_invitation.dart';
import '../backend/interfaces/post_service_interface.dart';
import '../backend/interfaces/gathering_service_interface.dart';
import '../backend/interfaces/poll_service_interface.dart';
import '../backend/interfaces/story_service_interface.dart';
import '../models/post.dart';
import '../models/gathering.dart';
import '../models/poll.dart';
import '../models/story.dart';
import '../services/app_status_service.dart';
import '../services/posts_cache.dart';
import '../services/posts_refresh_coordinator.dart';
import '../theme/app_theme.dart';
import '../widgets/branch_switcher_chip.dart';
import '../widgets/post_card.dart';
import '../widgets/gathering_card.dart';
import '../widgets/poll_card.dart';
import '../widgets/post_card_shimmer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/coach_mark_tour.dart';
import '../services/custom_api_notification_service.dart';
import '../utils/e2e_state_bridge.dart';
import '../utils/image_decode.dart';
import '../utils/perf_log.dart';
import '../utils/relative_details_route.dart';

part 'home_screen_sections.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  // Phase E2c: best-effort gathering feed. Nullable so the home screen
  // still works in tests / setups where the gathering provider isn't
  // registered — gatherings just don't appear, the post feed is unaffected.
  final GatheringServiceInterface? _gatheringService =
      GetIt.I.isRegistered<GatheringServiceInterface>()
          ? GetIt.I<GatheringServiceInterface>()
          : null;
  // Phase E5d: best-effort poll feed (same nullable pattern as gatherings).
  final PollServiceInterface? _pollService =
      GetIt.I.isRegistered<PollServiceInterface>()
          ? GetIt.I<PollServiceInterface>()
          : null;
  final StoryServiceInterface _storyService = GetIt.I<StoryServiceInterface>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  late final EventService _eventService;

  List<AppEvent> _upcomingEvents = [];
  List<Post> _posts = [];
  List<Gathering> _gatherings = const [];
  List<Poll> _polls = const [];
  List<Story> _stories = [];
  FamilyConnectionPrompt? _familyConnectionPrompt;
  String? _selectedEventCategoryFilter;
  bool _isLoadingEvents = true;
  bool _isLoadingPosts = false;
  bool _postsUnavailable = false;
  // null = unknown / not yet resolved. Drives the state-aware empty feed
  // CTA: false → tree has nobody but you (guide to add a relative);
  // true → there's family to post to (guide to write). Loaded lazily,
  // only when the feed comes back empty.
  bool? _hasFamilyAudience;
  bool _storiesUnavailable = false;
  bool _identityReviewsUnavailable = false;
  int _pendingIdentityReviewCount = 0;
  String? _currentTreeId;
  // Audience-mode feed filter. `null` = «Все» (post union across
  // every branch the viewer belongs to). When set, the feed is
  // narrowed to the chosen branch via the server-side treeId
  // filter. Independent of `_currentTreeId` (the BranchSwitcher
  // picks the active branch for tree-view / digest / events; the
  // feed has its own scope so a post in a different branch doesn't
  // silently drop out of view — that was the user-reported "тихая
  // потеря" bug).
  String? _selectedFeedBranchId;
  TreeProvider? _treeProviderInstance;
  // H (scroll-aware compose FAB): once the inline compose teaser scrolls
  // off the top of the feed, surface a compact «Написать» FAB so compose
  // stays reachable on a long feed. One dominant compose path per state
  // (teaser at top OR FAB below — never both).
  final ScrollController _feedScrollController = ScrollController();
  bool _showComposeFab = false;
  // S1: холодная лента замеряется один раз за жизнь экрана.
  bool _coldFeedTraced = false;
  // S3: курсорная пагинация (S2). Первая страница — _feedPageSize
  // постов; докрутка подтягивает следующую. nextCursor == null —
  // лента закончилась (или старый бэк отдал всё разом).
  static const int _feedPageSize = 20;
  String? _feedNextCursor;
  bool _isLoadingMorePosts = false;
  static const double _composeFabScrollThreshold = 200.0;

  // E (Week 7 §6): first-launch coach-mark tour anchored on real home
  // widgets. GlobalKeys live here so the tour can spotlight them.
  final GlobalKey _tourStoriesKey = GlobalKey();
  final GlobalKey _tourTeaserKey = GlobalKey();
  final GlobalKey _tourEventsKey = GlobalKey();
  bool _showCoachTour = false;
  Timer? _coachTourTimer;

  CustomApiNotificationService? get _customNotificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  IdentityServiceInterface? get _identityService =>
      GetIt.I.isRegistered<IdentityServiceInterface>()
          ? GetIt.I<IdentityServiceInterface>()
          : null;

  /// Phase 6.5+ auto-refresh: callback registered с
  /// PostsRefreshCoordinator. Notification arrives (WebSocket либо
  /// push) → coordinator debounces 500ms → calls this method →
  /// _loadPosts re-fetches с current branch filter. Identity-stable
  /// reference (а не closure-on-method) — required для unregister
  /// pattern в dispose.
  ///
  /// `prefer_function_declarations_over_variables` намеренно suppressed:
  /// stored closure captures `this` once, и идентичность объекта стабильна
  /// между `register` и `unregister`. Method tear-off равен по
  /// идентичности на SDK ≥ 2.15, но эксплицитная held reference
  /// делает intent явным и survives possible refactors of `_loadPosts`.
  // ignore: prefer_function_declarations_over_variables
  late final Future<void> Function() _feedRefreshCallback =
      () => _loadPosts(branchId: _selectedFeedBranchId);

  @override
  void initState() {
    super.initState();
    _eventService = EventService();
    _feedScrollController.addListener(_handleFeedScroll);
    // Twitter / GitHub-style "/" shortcut to focus search. Only on
    // desktop where physical keyboard is the primary input.
    HardwareKeyboard.instance.addHandler(_handleHomeKeyEvent);

    // Phase 6.5+ auto-refresh: register feed callback с coordinator.
    // Backend dispatches `post_created` notification → WebSocket
    // либо push → notification service routes к coordinator →
    // debounced 500ms → calls _feedRefreshCallback.
    PostsRefreshCoordinator.instance.register(_feedRefreshCallback);
    // Pair с on-resume stale-cache check: после background process
    // suspension push handler могло пропустить notification, поэтому
    // re-trigger coordinator при возврате юзера в app.
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeProviderInstance = Provider.of<TreeProvider>(context, listen: false);
      _treeProviderInstance!.addListener(_handleTreeChange);
      _currentTreeId = _treeProviderInstance!.selectedTreeId;
      _loadIdentityReviewSummary();
      // Feed always starts in audience mode («Все») — the viewer
      // sees posts from every branch they belong to, no silent
      // drops just because BranchSwitcher landed on a different
      // branch. They can narrow via the chip strip if they want.
      _loadPosts(branchId: null);
      if (_currentTreeId != null) {
        _loadFamilyConnectionPrompt(_currentTreeId!);
        _loadStories(_currentTreeId!);
        _loadEvents(_currentTreeId!);
      } else {
        setState(() {
          _isLoadingEvents = false;
          _selectedEventCategoryFilter = null;
        });
      }
      _maybeShowCoachTour();
    });
  }

  @override
  void dispose() {
    PostsRefreshCoordinator.instance.unregister(_feedRefreshCallback);
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleHomeKeyEvent);
    _treeProviderInstance?.removeListener(_handleTreeChange);
    _feedScrollController.removeListener(_handleFeedScroll);
    _coachTourTimer?.cancel();
    _feedScrollController.dispose();
    super.dispose();
  }

  /// H: toggle the compose FAB once the feed has scrolled past the inline
  /// teaser. Only the narrow CustomScrollView attaches this controller,
  /// so on wide layouts `hasClients` is false and the FAB stays hidden.
  void _handleFeedScroll() {
    if (!_feedScrollController.hasClients) return;
    final show = _feedScrollController.offset > _composeFabScrollThreshold;
    if (show != _showComposeFab && mounted) {
      setState(() => _showComposeFab = show);
    }
    // S3: докрутка к низу (за 600dp до конца) — тянем следующую
    // страницу. Гард от повторов внутри _loadMorePosts.
    final position = _feedScrollController.position;
    if (position.maxScrollExtent - position.pixels < 600) {
      unawaited(_loadMorePosts());
    }
  }

  /// E: show the first-launch coach-mark tour once a tree is open (i.e.
  /// after onboarding — not conflicting with the FE9 wizard which runs
  /// before any tree exists). Persisted, so it never repeats. Delayed a
  /// beat so the async stories/events sections lay out and the anchors
  /// have rects (missing anchors degrade gracefully to a centred bubble).
  Future<void> _maybeShowCoachTour() async {
    if (_currentTreeId == null) return;
    final should = await CoachMarkTour.shouldShow();
    if (!should || !mounted) return;
    // Cancellable timer (not Future.delayed) so dispose can tear it down
    // — keeps it from lingering as a pending timer in widget tests.
    _coachTourTimer?.cancel();
    _coachTourTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || _showCoachTour || _currentTreeId == null) return;
      setState(() => _showCoachTour = true);
    });
  }

  void _dismissCoachTour() {
    if (mounted) setState(() => _showCoachTour = false);
    CoachMarkTour.markShown();
  }

  List<CoachMarkTarget> _coachMarkTargets() {
    // Чанк B: тайл ближайшего события не рендерится без событий —
    // спотлайтить отсутствующий виджет нельзя (новый юзер часто без
    // событий). Нет тайла → шаг пропускаем целиком.
    final hasEventsTile = !_isLoadingEvents && _upcomingEvents.isNotEmpty;
    return <CoachMarkTarget>[
      CoachMarkTarget(
        key: _tourStoriesKey,
        title: 'Это твоё дерево',
        body: 'Здесь живёт твоя семья. Добавляй моменты — фото и '
            'короткие истории дня.',
      ),
      CoachMarkTarget(
        key: _tourTeaserKey,
        title: 'Делись с роднёй',
        body: 'Напиши новость, добавь фото или событие — близкие увидят '
            'это в ленте.',
      ),
      if (hasEventsTile)
        CoachMarkTarget(
          key: _tourEventsKey,
          title: 'Важные даты рядом',
          body: 'Дни рождения и события родных всегда на виду.',
        ),
    ];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Phase 6.5+ auto-refresh: re-request feed refresh когда app
    // возвращается из background — это catch'ит push notifications,
    // которые были delivered пока process suspended, и upstream
    // handler не успел route'ить к coordinator. Debounce внутри
    // coordinator coalesces с concurrent push arrival → no duplicate
    // network roundtrip.
    if (state != AppLifecycleState.resumed) return;
    PostsRefreshCoordinator.instance.requestRefresh();
  }

  /// Global hotkey handler — registered on HardwareKeyboard directly
  /// rather than via Focus.onKeyEvent because Flutter web's CanvasKit
  /// can swallow KeyDown events at the framework Focus layer.
  ///
  /// Currently supports:
  /// - "/" → push the search screen (Twitter / GitHub style). Skipped
  ///   when any TextField has focus so users typing "/" inside a
  ///   composer aren't hijacked.
  bool _handleHomeKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.slash) return false;
    final focused = FocusManager.instance.primaryFocus;
    final inEditable = focused?.context?.widget is EditableText ||
        (focused?.context != null &&
            focused!.context!.findAncestorWidgetOfExactType<EditableText>() !=
                null);
    if (inEditable) return false;
    // Don't fire for ?-shortcut or ctrl/cmd combos.
    if (HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    context.push('/post/search');
    return true;
  }

  void _handleTreeChange() {
    if (!mounted) return;
    final newTreeId = _treeProviderInstance?.selectedTreeId;
    if (_currentTreeId != newTreeId) {
      _currentTreeId = newTreeId;
      _loadIdentityReviewSummary();
      if (_currentTreeId != null) {
        _loadFamilyConnectionPrompt(_currentTreeId!);
        _loadStories(_currentTreeId!);
        _loadEvents(_currentTreeId!);
        // The feed is intentionally NOT reloaded on branch change —
        // it tracks `_selectedFeedBranchId`, not the active branch
        // of the BranchSwitcher. This is what fixes the "выбрал
        // мамину ветку, потерял пост из папиной" bug.
      } else {
        setState(() {
          _isLoadingEvents = false;
          _familyConnectionPrompt = null;
          _stories = [];
          _upcomingEvents = [];
          _selectedEventCategoryFilter = null;
        });
      }
    }
  }

  Future<void> _loadIdentityReviewSummary() async {
    final service = _identityService;
    if (service == null) {
      if (mounted) {
        setState(() {
          _pendingIdentityReviewCount = 0;
          _identityReviewsUnavailable = false;
        });
      }
      return;
    }

    try {
      final proposals = await service.getPendingMergeProposals();
      final claims = await service.getPendingIdentityClaims();
      if (!mounted) {
        return;
      }
      setState(() {
        // K1: баннер считает только предложения, ждущие решения ИМЕННО
        // зрителя — проголосовал → баннер погас, даже если консенсус
        // других ответственных ещё не собран.
        _pendingIdentityReviewCount =
            proposals.where((p) => p.awaitingMyDecision).length + claims.length;
        _identityReviewsUnavailable = false;
      });
    } catch (error) {
      debugPrint('Ошибка загрузки identity review summary: $error');
      if (mounted) {
        setState(() {
          _identityReviewsUnavailable = true;
        });
      }
    }
  }

  Future<void> _loadStories(String treeId) async {
    if (!mounted) return;
    setState(() {
      _storiesUnavailable = false;
    });
    try {
      final stories = await _storyService.getStories(treeId: treeId);
      if (mounted) {
        setState(() {
          _stories = stories;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки stories: $e');
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось обновить истории.',
      );
      if (mounted) {
        setState(() {
          _storiesUnavailable = true;
        });
      }
    }
  }

  Future<void> _loadEvents(String treeId) async {
    if (!mounted) return;
    setState(() {
      _isLoadingEvents = true;
      _upcomingEvents = [];
    });
    try {
      final events = await _eventService.getUpcomingEvents(treeId, limit: 10);
      if (mounted) {
        final categories = _collectEventCategories(events);
        setState(() {
          _upcomingEvents = events;
          if (_selectedEventCategoryFilter != null &&
              !categories.contains(_selectedEventCategoryFilter)) {
            _selectedEventCategoryFilter = null;
          }
          _isLoadingEvents = false;
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки событий: $e');
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось обновить события.',
      );
      if (mounted) {
        setState(() {
          _isLoadingEvents = false;
        });
      }
    }
  }

  Future<void> _loadFamilyConnectionPrompt(String treeId) async {
    if (!mounted) return;
    if (_treeProviderInstance?.selectedTreeKind == TreeKind.friends) {
      setState(() {
        _familyConnectionPrompt = null;
      });
      return;
    }

    try {
      final relatives = await _familyTreeService.getRelatives(treeId);
      if (!mounted || _currentTreeId != treeId) {
        return;
      }
      final prompt = FamilyConnectionPromptSelector.select(
        relatives: relatives,
        currentUserId: _authService.currentUserId,
      );
      setState(() {
        _familyConnectionPrompt = prompt;
      });
    } catch (error) {
      debugPrint('Ошибка загрузки family connection prompt: $error');
      if (mounted && _currentTreeId == treeId) {
        setState(() {
          _familyConnectionPrompt = null;
        });
      }
    }
  }

  List<String> _collectEventCategories(List<AppEvent> events) {
    final categories = <String>[];
    for (final event in events) {
      if (!categories.contains(event.categoryLabel)) {
        categories.add(event.categoryLabel);
      }
    }
    return categories;
  }

  List<String> get _eventCategories => _collectEventCategories(_upcomingEvents);

  List<AppEvent> get _visibleUpcomingEvents {
    final selectedCategory = _selectedEventCategoryFilter;
    if (selectedCategory == null || selectedCategory.isEmpty) {
      return _upcomingEvents;
    }
    return _upcomingEvents
        .where((event) => event.categoryLabel == selectedCategory)
        .toList();
  }

  /// What the home feed renders. After Step 1 there's no
  /// content-type narrowing (Семья/Близкие/Архив/Истории) — the
  /// only feed control is the branch chip strip, which already
  /// filters on the server side via `treeId`. Returning `_posts`
  /// directly keeps the data path predictable: whatever
  /// `_loadPosts` brought back is what the user sees.
  List<Post> get _visiblePosts => _posts;

  String _eventCategoryKey(String label) {
    switch (label) {
      case 'Родня':
        return 'rodnya';
      case 'Семья':
        return 'family';
      case 'Память':
        return 'memory';
      case 'Повод':
        return 'custom';
      case 'Россия':
        return 'russia';
      case 'Православие':
        return 'orthodox';
      case 'Календарь':
        return 'calendar';
      default:
        return label
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9а-я]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), '');
    }
  }

  void _publishHomeE2EState({
    required String? selectedTreeName,
    required bool hasSelectedTree,
  }) {
    if (!E2EStateBridge.isEnabled) {
      return;
    }

    final visibleEvents = _visibleUpcomingEvents;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // Чанк B: ключи eventRailOffset/eventRailMaxOffset/eventRailBounds/
      // webWheelEventCount удалены вместе с узким рельсом (Phase 2) —
      // grep по test/ tool/ e2e/ подтвердил: их никто не читает.
      E2EStateBridge.publish(
        screen: 'home',
        state: <String, dynamic>{
          'selectedTreeId': _currentTreeId,
          'selectedTreeName': selectedTreeName,
          'hasSelectedTree': hasSelectedTree,
          'isLoadingEvents': _isLoadingEvents,
          // After Step 1 the home feed has a single axis — branch
          // chips. Surface the branch scope so E2E tests can assert
          // on the chip strip directly. The legacy
          // selectedFeedFilter / availableFeedFilters were removed
          // along with the content-type chip strip.
          'selectedFeedBranchId': _selectedFeedBranchId,
          'selectedEventFilter': _selectedEventCategoryFilter,
          'availableEventFilters': <String>['Все', ..._eventCategories],
          'visibleEvents': visibleEvents
              .map(
                (event) => <String, dynamic>{
                  'id': event.id,
                  'title': event.title,
                  'category': event.categoryLabel,
                  'status': event.status,
                  'personId': event.personId,
                },
              )
              .toList(),
        },
      );
    });
  }

  PostsCache? get _postsCache =>
      GetIt.I.isRegistered<PostsCache>() ? GetIt.I<PostsCache>() : null;

  /// Sentinel cache key for the audience-mode feed (no branch
  /// filter). Real branchIds are UUIDs and never collide with this
  /// literal, so the cache stays uniquely keyable across the «Все»
  /// view and per-branch narrowed views.
  static const String _audienceFeedCacheKey = '__audience__';

  Future<void> _loadPosts({String? branchId}) async {
    if (!mounted) return;
    // S1: холодная загрузка ленты — от первого _loadPosts до кадра с
    // данными. Только первый заход (рефреши не считаем холодными).
    final PerfTrace? coldTrace =
        _coldFeedTraced ? null : PerfTrace('feed.cold-load');
    _coldFeedTraced = true;
    setState(() {
      _isLoadingPosts = true;
      // Don't surface "feed unavailable" the moment we start loading —
      // it'll flicker on every refresh. Only flip back if we actually
      // have no posts to show after the call fails.
    });
    // Phase E2c/E5d: pull gatherings + polls alongside posts (best-effort,
    // isolated — own try/catch, never block or error the post path below).
    unawaited(_loadGatherings(branchId: branchId));
    unawaited(_loadPolls(branchId: branchId));
    final cacheKey = branchId ?? _audienceFeedCacheKey;
    // Cache-first hydrate: serve disk-cached posts immediately so the
    // feed paints content even if we're offline / network is slow.
    final cache = _postsCache;
    if (cache != null && _posts.isEmpty) {
      try {
        final cached = await cache.read(cacheKey);
        if (cached.isNotEmpty && mounted && _selectedFeedBranchId == branchId) {
          setState(() {
            _posts = cached;
            _postsUnavailable = false;
          });
        }
      } catch (_) {
        // Cache read failure is non-fatal.
      }
    }
    try {
      // S3: первая страница через S2-курсор (старый бэк вернёт всё
      // разом — page.nextCursor будет null, поведение прежнее).
      final page = await _postService.getPostsPage(
        treeId: branchId,
        limit: _feedPageSize,
      );
      final posts = page.posts;
      // Race guard: another _loadPosts may have started while this
      // network call was in flight (user tapped a different chip).
      // Only commit if we're still the latest load for this branch.
      if (!mounted || _selectedFeedBranchId != branchId) {
        coldTrace?.cancel();
        return;
      }
      unawaited(cache?.write(cacheKey, posts));
      setState(() {
        _posts = posts;
        _feedNextCursor = page.nextCursor;
        _isLoadingPosts = false;
        _postsUnavailable = false;
      });
      if (coldTrace != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => coldTrace.finish('${posts.length} posts'),
        );
      }
      // Only resolve the audience signal when the feed is actually
      // empty — that's the only time the state-aware empty CTA shows,
      // so feeds with content never pay for the extra fetch.
      if (posts.isEmpty) {
        unawaited(_refreshFamilyAudienceSignal());
      }
    } catch (e) {
      coldTrace?.cancel();
      debugPrint('Ошибка загрузки постов: $e');
      _appStatusService.reportError(
        e,
        fallbackMessage: 'Не удалось обновить ленту.',
      );
      if (mounted) {
        setState(() {
          // Keep the existing _posts list so the user still sees what
          // they had cached / fetched previously. Only mark as
          // unavailable when we have NOTHING to show — that's the
          // case where the empty-state UI is the right answer.
          _postsUnavailable = _posts.isEmpty;
          _isLoadingPosts = false;
        });
      }
    }
  }

  /// Phase E2c: best-effort gathering load for the mixed feed. Gatherings
  /// are tree-scoped (no audience-aggregate endpoint), so they load for
  /// the selected branch or the current tree. A failure simply hides them
  /// — the post feed degrades independently and is never affected.
  Future<void> _loadGatherings({String? branchId}) async {
    final service = _gatheringService;
    final treeId = branchId ?? _currentTreeId;
    if (service == null || treeId == null) {
      if (_gatherings.isNotEmpty && mounted) {
        setState(() => _gatherings = const []);
      }
      return;
    }
    try {
      final gatherings = await service.getGatherings(treeId: treeId);
      // Same race guard the post load uses — discard if the user switched
      // branch while this was in flight.
      if (!mounted || _selectedFeedBranchId != branchId) return;
      setState(() => _gatherings = gatherings);
    } catch (_) {
      // Best-effort — leave whatever we had; never surface an error.
    }
  }

  /// Phase E5d: best-effort poll load. Polls support audience mode (the
  /// store + /v1/polls aggregate across all accessible circles when no
  /// treeId is sent), so we pass [branchId] straight through like posts:
  /// null → «Все» (all circles), non-null → that circle. Earlier this fell
  /// back to _currentTreeId, so a poll in another circle never showed under
  /// «Все» — only when its circle was explicitly selected.
  Future<void> _loadPolls({String? branchId}) async {
    final service = _pollService;
    if (service == null) {
      if (_polls.isNotEmpty && mounted) {
        setState(() => _polls = const []);
      }
      return;
    }
    try {
      final polls = await service.getPolls(treeId: branchId);
      if (!mounted || _selectedFeedBranchId != branchId) return;
      setState(() => _polls = polls);
    } catch (_) {
      // Best-effort — leave whatever we had; never surface an error.
    }
  }

  /// Posts + gatherings + polls merged into one newest-first feed (by
  /// createdAt). When there are no gatherings AND no polls the post list
  /// is returned verbatim — the server already orders posts newest-first,
  /// so we don't re-sort (keeps the post-only feed byte-identical).
  // S3: мерж-сортировка ленты кэшируется по identity исходных списков —
  // каждый rebuild раньше пересобирал и пересортировывал все entries
  // (на 200 постах это заметно в кадре). Источники всегда присваиваются
  // НОВЫМИ списками, так что identity-проверка корректна.
  List<_HomeFeedEntry>? _feedEntriesCache;
  List<Post>? _feedEntriesCachePosts;
  List<Gathering>? _feedEntriesCacheGatherings;
  List<Poll>? _feedEntriesCachePolls;

  List<_HomeFeedEntry> get _feedEntries {
    final cached = _feedEntriesCache;
    if (cached != null &&
        identical(_feedEntriesCachePosts, _posts) &&
        identical(_feedEntriesCacheGatherings, _gatherings) &&
        identical(_feedEntriesCachePolls, _polls)) {
      return cached;
    }
    final postEntries = [
      for (final post in _visiblePosts) _HomeFeedEntry.post(post),
    ];
    List<_HomeFeedEntry> entries;
    if (_gatherings.isEmpty && _polls.isEmpty) {
      entries = postEntries;
    } else {
      entries = <_HomeFeedEntry>[
        ...postEntries,
        for (final gathering in _gatherings)
          _HomeFeedEntry.gathering(gathering),
        for (final poll in _polls) _HomeFeedEntry.poll(poll),
      ];
      entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    _feedEntriesCache = entries;
    _feedEntriesCachePosts = _posts;
    _feedEntriesCacheGatherings = _gatherings;
    _feedEntriesCachePolls = _polls;
    return entries;
  }

  /// Resolve whether the active tree has anyone besides the current
  /// user, so the empty feed can guide a brand-new account to add a
  /// relative rather than write into the void (UX-audit 2.2). Relative
  /// person-cards carry `userId == null`; the viewer's own card carries
  /// their id — so "has audience" = any person that isn't the viewer.
  /// Best-effort: on failure the signal stays unknown and the feed
  /// falls back to the «Написать» CTA (prior behaviour).
  Future<void> _refreshFamilyAudienceSignal() async {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    try {
      final relatives = await _familyTreeService.getRelatives(treeId);
      if (!mounted) return;
      final currentUserId = _authService.currentUserId;
      final hasAudience =
          relatives.any((person) => person.userId != currentUserId);
      if (_hasFamilyAudience != hasAudience) {
        setState(() => _hasFamilyAudience = hasAudience);
      }
    } catch (_) {
      // Non-fatal — leave the signal unknown.
    }
  }

  /// S3: подгрузка следующей страницы при докрутке. Идемпотентна —
  /// повторные срабатывания скролла во время загрузки игнорируются.
  Future<void> _loadMorePosts() async {
    final cursor = _feedNextCursor;
    if (cursor == null || _isLoadingMorePosts || _isLoadingPosts) {
      return;
    }
    final branchId = _selectedFeedBranchId;
    _isLoadingMorePosts = true;
    try {
      final page = await _postService.getPostsPage(
        treeId: branchId,
        limit: _feedPageSize,
        before: cursor,
      );
      if (!mounted || _selectedFeedBranchId != branchId) {
        return;
      }
      // Дедуп по id: realtime-рефреш мог уже подмешать часть страницы.
      final existingIds = _posts.map((post) => post.id).toSet();
      final fresh = page.posts
          .where((post) => !existingIds.contains(post.id))
          .toList(growable: false);
      setState(() {
        _posts = [..._posts, ...fresh];
        _feedNextCursor = page.nextCursor;
      });
    } catch (error) {
      debugPrint('Ошибка подгрузки ленты: $error');
      // Без снэкбара: докрутка — фоновая операция, ретрай по следующему
      // скроллу.
    } finally {
      _isLoadingMorePosts = false;
    }
  }

  /// User tapped a chip in the feed-branch strip. `null` = «Все».
  void _selectFeedBranch(String? branchId) {
    if (_selectedFeedBranchId == branchId) return;
    setState(() {
      _selectedFeedBranchId = branchId;
      // Reset the loaded posts so the cache-first hydrate path
      // can re-fire for the new scope; otherwise stale posts from
      // the previous chip linger until the network call lands.
      _posts = const <Post>[];
    });
    _loadPosts(branchId: branchId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeProvider = Provider.of<TreeProvider>(context);
    final selectedTreeName = treeProvider.selectedTreeName;
    final selectedTreeKind = treeProvider.selectedTreeKind;
    final isFriendsTree = selectedTreeKind == TreeKind.friends;
    final hasSelectedTree = _currentTreeId != null && selectedTreeName != null;
    final isWideLayout = _isWideHomeLayout(context);
    _publishHomeE2EState(
      selectedTreeName: selectedTreeName,
      hasSelectedTree: hasSelectedTree,
    );

    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(AppTheme.topbarHeight(context)),
        child: _buildHomeTopbar(theme: theme, tokens: tokens),
      ),
      // Once the inline composer scrolls away, keep creation reachable in a
      // layout-owned action bar. A FAB used to cover the active post and its
      // reactions while the user read the feed.
      bottomNavigationBar: (hasSelectedTree && _showComposeFab)
          ? _buildComposeActionBar(tokens)
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          await _customNotificationService?.refreshUnreadNotificationsCount();
          await _loadIdentityReviewSummary();
          // Feed always refreshes — it's branch-independent. Stories
          // and events only refresh when there's an active branch
          // (those are tied to the BranchSwitcher selection).
          await _loadPosts(branchId: _selectedFeedBranchId);
          if (_currentTreeId != null) {
            await Future.wait([
              _loadFamilyConnectionPrompt(_currentTreeId!),
              _loadStories(_currentTreeId!),
              _loadEvents(_currentTreeId!),
            ]);
          }
        },
        child: StreamBuilder<List<TreeInvitation>>(
          stream: _familyTreeService.getPendingTreeInvitations(),
          builder: (context, snapshot) {
            final pendingInvitations =
                snapshot.data ?? const <TreeInvitation>[];
            final homeBody = _buildHomeBody(
              pendingInvitations: pendingInvitations,
              hasSelectedTree: hasSelectedTree,
              isWideLayout: isWideLayout,
              selectedTreeName: selectedTreeName,
              isFriendsTree: isFriendsTree,
            );
            if (!_showCoachTour) return homeBody;
            // Tour overlay sits over the home body (spotlights the
            // stories/teaser/events anchors). Below the app-bar + shell
            // nav, which it doesn't target.
            return Stack(
              children: [
                homeBody,
                CoachMarkTour(
                  targets: _coachMarkTargets(),
                  onDismiss: _dismissCoachTour,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildComposeActionBar(RodnyaDesignTokens tokens) {
    return Material(
      key: const Key('compose-action-bar'),
      color: tokens.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: SizedBox(
            height: 44,
            child: FilledButton.icon(
              key: const Key('compose-action'),
              onPressed: () => _openCreatePost(),
              icon: const Icon(Icons.edit_outlined, size: 20),
              label: const Text('Написать пост'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTopbar({
    required ThemeData theme,
    required RodnyaDesignTokens tokens,
  }) {
    // See profile_screen._buildProfileTopbar — same perf reasoning.
    // BackdropFilter is the heaviest per-frame cost on Samsung S20
    // FE class hardware; skip on Android and bump the surface alpha
    // to ~96% so the look is essentially preserved.
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
            // Q3: 6pt vertical (was 8) gives the 48pt touch targets room
            // inside the fixed-height bar; tighter horizontal insets
            // (14/8 was 18/12) reclaim the width the larger targets need.
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            child: Row(
              children: [
                // Brand + branch chip own all the space left of the icon
                // cluster. The Expanded (replacing the old Spacer) keeps the
                // icons right-aligned and lets the chip ellipsize cleanly no
                // matter how many icons sit beside it — a plain Flexible+Spacer
                // pair only handed the chip half the free space, which tipped
                // into an overflow once the topbar dropped to four icons.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Родня',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.serif(
                            color: tokens.ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Phase 6.1: branch switcher chip — tap opens a bottom
                      // sheet with all of the user's branches. Hidden when
                      // there's nothing to switch to (fresh account, no trees
                      // yet).
                      const Flexible(child: BranchSwitcherChip()),
                    ],
                  ),
                ),
                // Q3: icons sit flush — each button carries its own 5pt
                // transparent ring inside the 48pt touch target, which is
                // the visible gap, so no SizedBox separators are needed.
                // 2a: иконка альбома из топбара убрана — вход один,
                // подписанный тайл «Альбом семьи» в строке хабов (icon-only
                // входы старшие не находят).
                _buildTopbarIconButton(
                  tokens: tokens,
                  tooltip: 'Поиск по постам',
                  onTap: () => context.push('/post/search'),
                  child: Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: tokens.accent,
                  ),
                ),
                _buildTopbarIconButton(
                  tokens: tokens,
                  child: _buildNotificationsAction(tokens: tokens),
                  tooltip: 'Активность',
                  onTap: () => context.push('/notifications'),
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

  Widget _buildTopbarIconButton({
    required RodnyaDesignTokens tokens,
    required Widget child,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    // Q3: keep the 38pt visual chip but grow the touch target to the
    // Material-spec 48×48. The 5pt transparent ring around the chip is
    // also the inter-icon spacing, so the icons sit directly next to each
    // other (no extra SizedBox) and the cluster barely grows in width.
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Center(
              child: Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tokens.surfaceStrong,
                  border: Border.all(color: tokens.surfaceLine),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationsAction({required RodnyaDesignTokens tokens}) {
    final notificationService = _customNotificationService;
    final defaultIcon = Icon(
      Icons.notifications_outlined,
      size: 19,
      color: tokens.ink,
    );
    if (notificationService == null) {
      return defaultIcon;
    }

    return StreamBuilder<int>(
      stream: notificationService.unreadNotificationsCountStream,
      initialData: notificationService.unreadNotificationsCount,
      builder: (context, snapshot) {
        final unreadCount = snapshot.data ?? 0;
        if (unreadCount <= 0) {
          return defaultIcon;
        }
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            defaultIcon,
            Positioned(
              top: -6,
              right: -8,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: tokens.warm,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: tokens.surfaceStrong, width: 1.5),
                ),
                child: Center(
                  child: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: AppTheme.sans(
                      color: Colors.black87,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _isWideHomeLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1180;

  /// Wraps the home body. On narrow viewports we keep the legacy
  /// single-column phone layout (capped at 720). On wide desktop
  /// browsers we split into a feed + sidebar layout so the empty
  /// left/right margins ("выглядит как растянутый телефон") finally
  /// get used. Pending invitations / operational banner / no-tree
  /// state stay above the split as a top strip — they target the full
  /// width of the inner column either way.
  Widget _buildHomeBody({
    required List<TreeInvitation> pendingInvitations,
    required bool hasSelectedTree,
    required bool isWideLayout,
    required String? selectedTreeName,
    required bool isFriendsTree,
  }) {
    if (!isWideLayout) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            controller: _feedScrollController,
            slivers: [
              const SliverToBoxAdapter(child: OnboardingResumeBanner()),
              const SliverToBoxAdapter(child: BatteryOptimizationCard()),
              if (pendingInvitations.isNotEmpty)
                SliverToBoxAdapter(
                  child: _buildPendingInvitationsBanner(pendingInvitations),
                ),
              if (_shouldShowOperationalBanner(hasSelectedTree))
                SliverToBoxAdapter(
                  child: _buildOperationalBanner(
                    hasSelectedTree: hasSelectedTree,
                  ),
                ),
              if (!hasSelectedTree)
                SliverToBoxAdapter(
                  child: _buildHomeHeader(
                    hasSelectedTree: hasSelectedTree,
                    selectedTreeName: selectedTreeName,
                    isFriendsTree: isFriendsTree,
                  ),
                ),
              if (hasSelectedTree) ...[
                SliverToBoxAdapter(child: _buildFeedHeaderSections()),
                _buildNarrowFeedSliver(),
                SliverToBoxAdapter(
                  child: _buildFamilyConnectionPromptCard(),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ] else
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      );
    }

    // Wide-layout: feed column (~720) + contextual sidebar (~340)
    // anchored to the top. Banners + identity-review banner pin to a
    // strip across the top so they don't get swallowed by the sidebar.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          // S3: общий контроллер с narrow-лентой (раскладки
          // взаимоисключающие) — докрутка тянет следующую страницу и
          // на wide, где живёт владелец с web-десктопа.
          controller: _feedScrollController,
          slivers: [
            const SliverToBoxAdapter(child: OnboardingResumeBanner()),
            const SliverToBoxAdapter(child: BatteryOptimizationCard()),
            if (pendingInvitations.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildPendingInvitationsBanner(pendingInvitations),
              ),
            if (_shouldShowOperationalBanner(hasSelectedTree))
              SliverToBoxAdapter(
                child: _buildOperationalBanner(
                  hasSelectedTree: hasSelectedTree,
                ),
              ),
            if (!hasSelectedTree)
              SliverToBoxAdapter(
                child: _buildHomeHeader(
                  hasSelectedTree: hasSelectedTree,
                  selectedTreeName: selectedTreeName,
                  isFriendsTree: isFriendsTree,
                ),
              ),
            if (hasSelectedTree) ...[
              SliverToBoxAdapter(
                child: _buildWideHomeColumns(),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ] else
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  /// Two-column layout for wide viewports. Left = feed-shaped column
  /// (compose teaser, filters, posts) capped at ~720 so post media
  /// stays readable. Right = sidebar with stories rail and the events
  /// digest, sticky-feeling because it's positioned next to (rather
  /// than above) the feed.
  Widget _buildWideHomeColumns() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Feed column.
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _buildHomeFeedColumn(),
            ),
          ),
          const SizedBox(width: 24),
          // Sidebar column.
          SizedBox(
            width: 340,
            child: _buildHomeSidebarColumn(),
          ),
        ],
      ),
    );
  }

  bool _shouldShowOperationalBanner(bool hasSelectedTree) {
    if (_appStatusService.hasVisibleStatus) {
      return true;
    }
    if (!hasSelectedTree) {
      return false;
    }
    return _postsUnavailable || _storiesUnavailable;
  }

  Widget _buildDesktopSideCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    return GlassPanel(
      padding: padding,
      borderRadius: BorderRadius.circular(22),
      child: child,
    );
  }

  Widget _buildHomeFeedStage({required bool isWideLayout}) {
    final feed = _buildFeedContent(wideLayout: isWideLayout);
    if (!isWideLayout) {
      return feed;
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: feed,
      ),
    );
  }

  Widget _buildHeaderChip({
    required IconData icon,
    required String label,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.9),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: highlighted
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: highlighted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final style = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    );
    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        style: style,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onTap,
      style: style,
      icon: Icon(icon),
      label: Text(label),
    );
  }

  /// 2b: слим-строка приглашений (~56dp вместо двухэтажной карточки).
  /// Вся строка — один тап в селектор приглашений; трейлинг «Открыть»
  /// сохранён как явная подпись действия (и точка тапа в тестах).
  Widget _buildPendingInvitationsBanner(List<TreeInvitation> invitations) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);
    final count = invitations.length;
    final firstTreeName = invitations.first.tree.name.trim();
    final title = count == 1
        ? (firstTreeName.isNotEmpty ? firstTreeName : 'Новое приглашение')
        : '$count приглашения';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const Key('home-invitations-banner'),
          onTap: () => context.go('/tree?selector=1&tab=invitations'),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onTertiaryContainer
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.mark_email_unread_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.sans(
                          color: tokens.ink,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        count == 1
                            ? 'Приглашение в семью — откройте и примите'
                            : 'Откройте список приглашений',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.sans(
                          color: tokens.inkMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Открыть',
                  style: AppTheme.sans(
                    color: tokens.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: tokens.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 2a: тяжёлый горизонтальный рельс «Ближайшие события» (шапка + чипы +
  // рельс + стрелки, ~100-130dp) на узкой раскладке заменён компактным
  // тайлом ближайшего события в строке хабов (_buildHomeHubTiles).
  // Полные фильтры + стек событий остаются на широкой раскладке — в
  // сайдбаре (_buildSidebarUpcomingEvents).

  Widget _buildEventFilterChip({
    required String label,
    required String semanticLabel,
    required bool selected,
    required VoidCallback onTap,
  }) {
    // 2c: дефолтные density + padded tap-target вместо compact/shrinkWrap —
    // чип остаётся визуально лёгким, но хит-зона дотягивает до ≥44dp
    // (старшим не приходится целиться).
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  /// Vertical events list for the wide-layout sidebar. Renders the
  /// same EventCards the horizontal rail uses but stacked instead of
  /// scrolled sideways — much friendlier on a 340dp column. Caps at
  /// 5 visible cards to keep the sidebar height reasonable; "Все
  /// события" link sits below the cap when there's more.
  Widget _buildSidebarUpcomingEvents() {
    final visibleEvents = _visibleUpcomingEvents;
    if (_isLoadingEvents || visibleEvents.isEmpty) {
      return const SizedBox.shrink();
    }
    final categories = _eventCategories;
    final hasCategories = categories.isNotEmpty;
    final cap = 5;
    final displayed = visibleEvents.take(cap).toList();
    final overflow = visibleEvents.length - displayed.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasCategories) ...[
          SizedBox(
            // 2c: 44dp — полный тап-таргет для чипов-фильтров (было 30).
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildEventFilterChip(
                  label: 'Все',
                  semanticLabel: 'home-event-filter-all',
                  selected: _selectedEventCategoryFilter == null,
                  onTap: () => setState(
                    () => _selectedEventCategoryFilter = null,
                  ),
                ),
                for (final category in categories) ...[
                  const SizedBox(width: 6),
                  _buildEventFilterChip(
                    label: category,
                    semanticLabel:
                        'home-event-filter-${_eventCategoryKey(category)}',
                    selected: _selectedEventCategoryFilter == category,
                    onTap: () => setState(
                      () => _selectedEventCategoryFilter = category,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (var i = 0; i < displayed.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          EventCard(
            event: displayed[i],
            compact: true,
            width: double.infinity,
          ),
        ],
        if (overflow > 0) ...[
          const SizedBox(height: 10),
          Center(
            child: Text(
              'и ещё $overflow',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStoriesSection() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final currentUserId = _authService.currentUserId ?? '';
    final byAuthor = <String, Story>{};
    for (final story in _stories) {
      final existing = byAuthor[story.authorId];
      if (existing == null || story.createdAt.isAfter(existing.createdAt)) {
        byAuthor[story.authorId] = story;
      }
    }
    final ordered = byAuthor.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return SizedBox(
      height: 88,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        children: [
          KeyedSubtree(
            key: _tourStoriesKey,
            child: _StoryRing(
              tokens: tokens,
              isAdd: true,
              label: 'Создать',
              onTap: () async {
                final result = await context.push('/stories/create');
                if (result == true && _currentTreeId != null) {
                  _loadStories(_currentTreeId!);
                }
              },
            ),
          ),
          for (final story in ordered)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _StoryRing(
                tokens: tokens,
                isAdd: false,
                label: story.authorName.split(' ').first,
                photoUrl: story.authorPhotoUrl,
                initials: _initialsFor(story.authorName),
                read: story.viewedBy.contains(currentUserId),
                onTap: () async {
                  final stories = _stories
                      .where((s) => s.authorId == story.authorId)
                      .toList();
                  if (stories.isEmpty) return;
                  final route =
                      '/stories/view/${story.treeId}/${story.authorId}';
                  await context.push(route);
                  if (_currentTreeId != null) {
                    _loadStories(_currentTreeId!);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  String _initialsFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts =
        trimmed.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      final a = String.fromCharCode(parts[0].runes.first);
      final b = String.fromCharCode(parts[1].runes.first);
      return (a + b).toUpperCase();
    }
    return String.fromCharCode(parts.first.runes.first).toUpperCase();
  }
}

class _StoryRing extends StatelessWidget {
  const _StoryRing({
    required this.tokens,
    required this.isAdd,
    required this.label,
    required this.onTap,
    this.photoUrl,
    this.initials,
    this.read = false,
  });

  final RodnyaDesignTokens tokens;
  final bool isAdd;
  final String label;
  final VoidCallback onTap;
  final String? photoUrl;
  final String? initials;
  final bool read;

  @override
  Widget build(BuildContext context) {
    final ringColor = isAdd
        ? tokens.accent
        : (read ? tokens.surfaceLine.withValues(alpha: 0.55) : tokens.accent);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: !isAdd && !read
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [tokens.accent, tokens.warm],
                      )
                    : null,
                color: (isAdd || read) ? Colors.transparent : null,
                border: (isAdd || read)
                    ? Border.all(color: ringColor, width: 1.6)
                    : null,
              ),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tokens.surfaceStrong,
                  border: Border.all(color: tokens.surfaceLine, width: 1),
                ),
                child: ClipOval(
                  // CachedNetworkImage (vs Image.network) so the
                  // story-rail avatars come from the shared image cache
                  // instead of re-downloading on every home rebuild —
                  // the rail re-runs build on any home setState. Initials
                  // stand in both while loading and on error. The parent
                  // story tile carries the author name as its semantic
                  // label, so the avatar is decorative for screen readers.
                  child: isAdd
                      ? Center(
                          child: Icon(
                            Icons.add_rounded,
                            size: 22,
                            color: tokens.accent,
                          ),
                        )
                      : (photoUrl != null && photoUrl!.isNotEmpty)
                          ? CachedNetworkImage(
                              imageUrl: photoUrl!,
                              fit: BoxFit.cover,
                              // M2: сторис-кружок ленты — 64dp.
                              memCacheWidth: decodeCacheWidth(context, 64),
                              placeholder: (_, __) => _initialsLabel(),
                              errorWidget: (_, __, ___) => _initialsLabel(),
                            )
                          : _initialsLabel(),
                ),
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              width: 64,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTheme.sans(
                  color: tokens.inkSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _initialsLabel() => Center(
        child: Text(
          initials ?? '?',
          style: AppTheme.sans(
            color: tokens.ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}
