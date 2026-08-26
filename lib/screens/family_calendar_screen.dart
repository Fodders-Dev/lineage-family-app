// Calendar v1 (calendar/A): «Календарь» — a month grid of the family's
// dates + holidays. Pure client-side: every date comes from
// EventService.getEventsForMonth (no backend). table_calendar handles
// leap-years / weekday layout / month navigation; we feed it events via
// eventLoader and colour the day-markers by category. Tap a day → the
// list of that day's events (shared EventCard).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';

import '../models/app_event.dart';
import '../providers/tree_provider.dart';
import '../services/event_service.dart';
import '../theme/app_theme.dart';
import '../utils/moon_phase.dart';
import '../utils/relative_details_route.dart';
import '../widgets/event_card.dart';

// M1: эмодзи-глиф из ячеек сетки и постоянная легенда убраны (вендорные
// эмодзи-шрифты Samsung закрашивали числа). Полный глиф фазы остаётся в
// tip-полосе (_buildMoonTip, fontSize 18) и текстах дня.

class FamilyCalendarScreen extends StatefulWidget {
  const FamilyCalendarScreen({
    super.key,
    this.serviceOverride,
    this.treeId,
    this.initialMonth,
  });

  /// Test seams — production builds an EventService and reads the tree
  /// from the TreeProvider.
  final EventService? serviceOverride;
  final String? treeId;
  final DateTime? initialMonth;

  @override
  State<FamilyCalendarScreen> createState() => _FamilyCalendarScreenState();
}

/// K2: вид календаря — месячная сетка или agenda-список на 90 дней.
enum _CalendarViewMode { month, list }

class _FamilyCalendarScreenState extends State<FamilyCalendarScreen> {
  late final EventService _service = widget.serviceOverride ?? EventService();
  String? _treeId;
  bool _loading = true;
  bool _loadFailed = false;
  late DateTime _focusedDay = widget.initialMonth ?? DateTime.now();
  late DateTime _selectedDay = widget.initialMonth ?? DateTime.now();
  Map<DateTime, List<AppEvent>> _eventsByDay = const {};
  TreeProvider? _treeProvider;

  // K2: agenda-список (90 дней вперёд). Грузится лениво при первом
  // переключении, сбрасывается при смене дерева/создании встречи.
  _CalendarViewMode _viewMode = _CalendarViewMode.month;
  List<AppEvent>? _agendaEvents;
  bool _agendaLoading = false;
  bool _agendaFailed = false;
  final ScrollController _agendaController = ScrollController();
  bool _agendaScrolledAway = false;

  @override
  void initState() {
    super.initState();
    _agendaController.addListener(_handleAgendaScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _treeId = widget.treeId;
      // Now a kept-alive nav tab (was a one-off pushed page): bind to the
      // TreeProvider when no explicit treeId is injected, so switching the
      // active branch elsewhere reloads this tab's events instead of
      // showing the previously-loaded tree.
      if (widget.treeId == null) {
        try {
          _treeProvider = context.read<TreeProvider>()
            ..addListener(_handleTreeChange);
          _treeId = _treeProvider!.selectedTreeId;
        } catch (_) {
          _treeId = null;
        }
      }
      _loadMonth(_focusedDay);
    });
  }

  void _handleTreeChange() {
    if (!mounted) return;
    final newTreeId = _treeProvider?.selectedTreeId;
    if (newTreeId == _treeId) return;
    setState(() {
      _treeId = newTreeId;
      _eventsByDay = const {};
      _agendaEvents = null;
    });
    _loadMonth(_focusedDay);
    if (_viewMode == _CalendarViewMode.list) {
      _loadAgenda();
    }
  }

  void _handleAgendaScroll() {
    if (!_agendaController.hasClients) return;
    final scrolledAway = _agendaController.offset > 240;
    if (scrolledAway != _agendaScrolledAway && mounted) {
      setState(() => _agendaScrolledAway = scrolledAway);
    }
  }

  @override
  void dispose() {
    _treeProvider?.removeListener(_handleTreeChange);
    _agendaController.removeListener(_handleAgendaScroll);
    _agendaController.dispose();
    super.dispose();
  }

  DateTime _dayKey(DateTime day) => DateTime(day.year, day.month, day.day);

  bool get _hasTree => _treeId != null && _treeId!.trim().isNotEmpty;

  Future<void> _loadMonth(DateTime month) async {
    final treeId = _treeId;
    if (treeId == null || treeId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      final events =
          await _service.getEventsForMonth(treeId, month.year, month.month);
      if (!mounted) return;
      final grouped = <DateTime, List<AppEvent>>{};
      for (final e in events) {
        grouped.putIfAbsent(_dayKey(e.date), () => <AppEvent>[]).add(e);
      }
      setState(() {
        _eventsByDay = grouped;
        _loading = false;
      });
    } catch (_) {
      // Surface the failure instead of showing an empty month (CP-2).
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  List<AppEvent> _eventsFor(DateTime day) {
    final events = _eventsByDay[_dayKey(day)];
    if (events == null) return const <AppEvent>[];
    return List<AppEvent>.of(events)..sort(_compareWithinDay);
  }

  /// K3: внутри одного дня семейные даты (дни рождения, годовщины — всё,
  /// что привязано к человеку) всегда выше праздников.
  int _compareWithinDay(AppEvent a, AppEvent b) {
    final aFamily = a.isLinkedToPerson ? 0 : 1;
    final bFamily = b.isLinkedToPerson ? 0 : 1;
    if (aFamily != bFamily) return aFamily - bFamily;
    return a.title.compareTo(b.title);
  }

  /// K2: agenda — ближайшие 90 дней одной прокруткой. Собираем из
  /// помесячного источника (текущий + 3 следующих месяца покрывают
  /// диапазон), фильтруем окно и сортируем: день → семейные выше
  /// праздников.
  Future<void> _loadAgenda() async {
    final treeId = _treeId;
    if (treeId == null || treeId.isEmpty) return;
    if (mounted) {
      setState(() {
        _agendaLoading = true;
        _agendaFailed = false;
      });
    }
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final horizon = today.add(const Duration(days: 90));
      final monthFutures = <Future<List<AppEvent>>>[];
      for (var i = 0; i < 4; i++) {
        final month = DateTime(today.year, today.month + i, 1);
        monthFutures.add(
          _service.getEventsForMonth(treeId, month.year, month.month),
        );
      }
      final monthly = await Future.wait(monthFutures);
      if (!mounted) return;
      final events = monthly.expand((events) => events).where((event) {
        final day = _dayKey(event.date);
        return !day.isBefore(today) && !day.isAfter(horizon);
      }).toList()
        ..sort((a, b) {
          final byDay = _dayKey(a.date).compareTo(_dayKey(b.date));
          if (byDay != 0) return byDay;
          return _compareWithinDay(a, b);
        });
      setState(() {
        _agendaEvents = events;
        _agendaLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _agendaLoading = false;
          _agendaFailed = true;
        });
      }
    }
  }

  void _switchView(_CalendarViewMode mode) {
    if (_viewMode == mode) return;
    setState(() => _viewMode = mode);
    if (mode == _CalendarViewMode.list && _agendaEvents == null) {
      _loadAgenda();
    }
  }

  /// K2: GCal-фишка «Сегодня» — в месяце прыжок к текущему месяцу с
  /// выделением дня, в списке — скролл к началу («Сегодня» всегда сверху).
  bool get _showTodayButton {
    if (_viewMode == _CalendarViewMode.list) {
      return _agendaScrolledAway;
    }
    final now = DateTime.now();
    return _focusedDay.year != now.year || _focusedDay.month != now.month;
  }

  void _jumpToToday() {
    final now = DateTime.now();
    if (_viewMode == _CalendarViewMode.list) {
      if (_agendaController.hasClients) {
        _agendaController.animateTo(
          0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    setState(() {
      _focusedDay = now;
      _selectedDay = now;
    });
    _loadMonth(now);
  }

  /// K2: создание встречи с предзаполненной датой (выбранный день).
  /// По возврату перечитываем месяц и agenda — свежая встреча сразу
  /// видна в календаре.
  Future<void> _createGatheringFor(DateTime day) async {
    final dateParam = DateFormat('yyyy-MM-dd').format(day);
    await context.push('/gathering/create?date=$dateParam');
    if (!mounted) return;
    await _loadMonth(_focusedDay);
    if (!mounted) return;
    if (_agendaEvents != null || _viewMode == _CalendarViewMode.list) {
      await _loadAgenda();
    }
  }

  Color _markerColor(
    AppEventType type,
    ThemeData theme,
    RodnyaDesignTokens tokens,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    switch (type) {
      case AppEventType.russianHoliday:
        // Flag red, lifted for dark backgrounds.
        return isDark ? const Color(0xFFE57373) : const Color(0xFFD64545);
      case AppEventType.orthodoxHoliday:
        // Soft violet, lifted for dark backgrounds.
        return isDark ? const Color(0xFFB39DDB) : const Color(0xFF8E7CC3);
      case AppEventType.folkHoliday:
        // K3: тёплый янтарь — народные различимы от красного (гос) и
        // фиолетового (православные) даже точкой 7px.
        return isDark ? const Color(0xFFE0BC4C) : const Color(0xFFB8860B);
      default:
        return tokens.accent; // family — on-brand accent
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);
    final selectedEvents = _eventsFor(_selectedDay);
    final isListView = _viewMode == _CalendarViewMode.list;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Календарь'),
        actions: [
          // K2 (GCal): «Сегодня» — в месяце прыжок к текущему месяцу,
          // в списке скролл к началу. Видна, когда юзер «ушёл».
          if (_showTodayButton)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton.icon(
                key: const Key('calendar-today'),
                onPressed: _jumpToToday,
                icon: const Icon(Icons.today_outlined, size: 20),
                label: const Text(
                  'Сегодня',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (_hasTree)
            IconButton(
              key: const Key('calendar-create-gathering'),
              tooltip: 'Создать встречу',
              onPressed: () => _createGatheringFor(_selectedDay),
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      body: Column(
        key: const Key('calendar-body'),
        children: [
          _buildViewToggle(theme, tokens),
          if (isListView)
            Expanded(child: _buildAgendaBody(theme, tokens))
          else ...[
            _buildCalendar(theme, tokens),
            // M1: постоянная легенда фаз убрана — фаза выбранного дня и
            // так в tip-полосе под сеткой.
            const Divider(height: 1),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!_hasTree)
              Expanded(child: _buildNoTree(theme, tokens))
            else if (_loadFailed)
              Expanded(child: _buildError(theme, tokens))
            else ...[
              _buildMoonTip(theme, tokens, _selectedDay),
              Expanded(
                child: selectedEvents.isEmpty
                    ? _buildDayEmpty(theme, tokens)
                    : _buildDayList(selectedEvents),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// K2: тумблер [Месяц | Список] — тот же визуальный паттерн, что
  /// Список⇄Дерево в «Семье» (сегменты ≥44dp).
  Widget _buildViewToggle(ThemeData theme, RodnyaDesignTokens tokens) {
    Widget segment({
      required Key key,
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Material(
          color: selected ? tokens.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(11),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: selected ? tokens.accentInk : tokens.inkMuted,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: AppTheme.sans(
                      color: selected ? tokens.accentInk : tokens.inkMuted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: tokens.surfaceStrong,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.surfaceLine),
        ),
        child: Row(
          children: [
            segment(
              key: const Key('calendar-view-month'),
              icon: Icons.calendar_month_outlined,
              label: 'Месяц',
              selected: _viewMode == _CalendarViewMode.month,
              onTap: () => _switchView(_CalendarViewMode.month),
            ),
            segment(
              key: const Key('calendar-view-list'),
              icon: Icons.view_agenda_outlined,
              label: 'Список',
              selected: _viewMode == _CalendarViewMode.list,
              onTap: () => _switchView(_CalendarViewMode.list),
            ),
          ],
        ),
      ),
    );
  }

  /// K2: agenda в стиле Google Calendar — ближайшие 90 дней одной
  /// прокруткой, сгруппированы по дням, бейдж категории на каждом.
  Widget _buildAgendaBody(ThemeData theme, RodnyaDesignTokens tokens) {
    if (!_hasTree) return _buildNoTree(theme, tokens);
    if (_agendaLoading || (_agendaEvents == null && !_agendaFailed)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_agendaFailed) {
      return _scrollSafeCenter(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48, color: tokens.inkMuted),
              const SizedBox(height: 12),
              Text(
                'Не удалось загрузить',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'Lora',
                  fontWeight: FontWeight.w700,
                  color: tokens.ink,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                key: const Key('calendar-agenda-retry'),
                onPressed: _loadAgenda,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    final events = _agendaEvents!;
    if (events.isEmpty) {
      return _scrollSafeCenter(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_available_outlined,
                size: 48,
                color: tokens.inkMuted,
              ),
              const SizedBox(height: 12),
              Text(
                'Ближайшие 90 дней спокойные',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'Lora',
                  fontWeight: FontWeight.w700,
                  color: tokens.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Добавьте родным даты рождения — и календарь напомнит о каждом празднике.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: tokens.inkMuted),
              ),
            ],
          ),
        ),
      );
    }

    // Группировка по дням, заголовки «Сегодня · …» / «Завтра · …» / дата.
    final items = <Widget>[];
    DateTime? currentDay;
    for (final event in events) {
      final day = _dayKey(event.date);
      if (currentDay == null || day != currentDay) {
        currentDay = day;
        items.add(_buildAgendaDayHeader(theme, tokens, day));
      }
      items.add(_buildAgendaTile(theme, tokens, event));
    }

    return ListView(
      key: const Key('calendar-agenda-list'),
      controller: _agendaController,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      children: items,
    );
  }

  Widget _buildAgendaDayHeader(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    DateTime day,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    final dateLabel = DateFormat('EEEE, d MMMM', 'ru').format(day);
    final label = diff == 0
        ? 'Сегодня · $dateLabel'
        : diff == 1
            ? 'Завтра · $dateLabel'
            : dateLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        diff == 0 ? label : label[0].toUpperCase() + label.substring(1),
        key: diff == 0 ? const Key('calendar-agenda-today') : null,
        style: theme.textTheme.titleSmall?.copyWith(
          fontFamily: 'Lora',
          fontWeight: FontWeight.w700,
          color: diff == 0 ? tokens.accentStrong : tokens.ink,
        ),
      ),
    );
  }

  Widget _buildAgendaTile(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    AppEvent event,
  ) {
    final color = _markerColor(event.type, theme, tokens);
    final age = event.ageAtEvent;
    final title = event.isLinkedToPerson ? event.personName : event.title;
    final subtitleParts = <String>[
      if (event.isLinkedToPerson) event.title,
      if (age != null) 'исполнится $age',
      event.status,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openAgendaEvent(event),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(event.icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.sans(
                          color: tokens.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitleParts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.sans(
                          color: tokens.inkMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // K3: бейдж категории — различимость без чтения подписи.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    event.categoryLabel,
                    style: AppTheme.sans(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openAgendaEvent(AppEvent event) {
    if (event.isLinkedToPerson) {
      context.push(
        relativeDetailsRoute(event.personId, treeId: event.treeId),
      );
      return;
    }
    _showHolidayInfo(event);
  }

  Widget _buildCalendar(ThemeData theme, RodnyaDesignTokens tokens) {
    return TableCalendar<AppEvent>(
      locale: 'ru_RU',
      firstDay: DateTime.utc(2000, 1, 1),
      lastDay: DateTime.utc(2100, 12, 31),
      focusedDay: _focusedDay,
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      eventLoader: _eventsFor,
      startingDayOfWeek: StartingDayOfWeek.monday,
      availableGestures: AvailableGestures.horizontalSwipe,
      // M1: укрупнение под старших и 720-экраны — выше строка, крупнее
      // числа; последняя строка месяца рендерится целиком (виджет
      // shrink-wrap'ится в Column, высота строки задана явно).
      rowHeight: 54,
      headerStyle: HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'Lora',
              fontWeight: FontWeight.w700,
              color: tokens.ink,
            ) ??
            TextStyle(color: tokens.ink),
        leftChevronIcon: Icon(Icons.chevron_left, color: tokens.ink),
        rightChevronIcon: Icon(Icons.chevron_right, color: tokens.ink),
      ),
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle:
            TextStyle(color: tokens.inkMuted, fontWeight: FontWeight.w600),
        weekendStyle:
            TextStyle(color: tokens.inkMuted, fontWeight: FontWeight.w600),
      ),
      calendarStyle: CalendarStyle(
        outsideDaysVisible: false,
        isTodayHighlighted: true,
        // Force on-brand, theme-aware day text — Material defaults didn't
        // track the warm palette and the number on the green selected
        // circle was low-contrast / unreadable in dark mode.
        // M1: числа дней — bodyLarge-масштаб (16), читаемо на 720×1560.
        defaultTextStyle: TextStyle(color: tokens.ink, fontSize: 16),
        weekendTextStyle: TextStyle(color: tokens.ink, fontSize: 16),
        todayTextStyle: TextStyle(
          color: tokens.ink,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        selectedTextStyle: TextStyle(
          color: tokens.accentInk,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        todayDecoration: BoxDecoration(
          color: tokens.accent.withValues(alpha: 0.28),
          shape: BoxShape.circle,
        ),
        selectedDecoration: BoxDecoration(
          color: tokens.accent,
          shape: BoxShape.circle,
        ),
      ),
      calendarBuilders: CalendarBuilders<AppEvent>(
        // Moon marker (M1): только ~4 принципиальных дня в месяц. Раньше в
        // ячейке рисовался эмодзи-глиф (Positioned, fontSize 12) — на
        // Samsung вендорный эмодзи-шрифт рендерится крупнее и ЗАКРАШИВАЛ
        // число дня. Теперь число всегда доминирует, а фазу отмечает
        // тонкое кольцо вокруг ячейки; полный глиф + название фазы живут
        // в tip-полосе под сеткой и в списке дня.
        defaultBuilder: (context, day, focusedDay) {
          if (!isPrincipalMoonDay(day)) return null;
          return Center(
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: tokens.inkMuted.withValues(alpha: 0.55),
                  width: 1.4,
                ),
              ),
              child: Text(
                '${day.day}',
                style: TextStyle(color: tokens.ink, fontSize: 16),
              ),
            ),
          );
        },
        markerBuilder: (context, day, events) {
          if (events.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // M1: 7px вместо 5 — маркеры различимы на 720-экране.
                for (final e in events.take(3))
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: _markerColor(e.type, theme, tokens),
                      shape: BoxShape.circle,
                    ),
                  ),
                // More than three events that day → «+N» overflow hint.
                if (events.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      '+${events.length - 3}',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: tokens.inkMuted,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      onDaySelected: (selectedDay, focusedDay) {
        setState(() {
          _selectedDay = selectedDay;
          _focusedDay = focusedDay;
        });
      },
      onPageChanged: (focusedDay) {
        // K2: setState — кнопка «Сегодня» в AppBar реагирует на листание.
        setState(() => _focusedDay = focusedDay);
        _loadMonth(focusedDay);
      },
    );
  }

  /// Compact warm strip: the selected day's moon phase + a folk gardening
  /// tip (for the dacha crowd). One line — kept deliberately light.
  Widget _buildMoonTip(
    ThemeData theme,
    RodnyaDesignTokens tokens,
    DateTime day,
  ) {
    final phase = moonPhaseFor(day);
    return Container(
      key: const Key('moon-tip'),
      margin: EdgeInsets.fromLTRB(
        tokens.space12,
        tokens.space12,
        tokens.space12,
        tokens.space4,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.space12,
        vertical: tokens.space8,
      ),
      decoration: BoxDecoration(
        color: tokens.warmSoft,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
      child: Row(
        children: [
          Text(phase.glyph, style: const TextStyle(fontSize: 18)),
          SizedBox(width: tokens.space8),
          Expanded(
            child: Text(
              gardeningTip(phase),
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.ink,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDayList(List<AppEvent> events) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: events.length,
      itemBuilder: (_, i) {
        return Padding(
          key: Key('calendar-day-event-$i'),
          padding: const EdgeInsets.only(bottom: 8),
          child: EventCard(
            event: events[i],
            width: double.infinity,
            // Person-linked events ignore this and open the profile; a
            // holiday has no person, so the tap shows its info instead.
            onTap: () => _showHolidayInfo(events[i]),
          ),
        );
      },
    );
  }

  /// Bottom-sheet with a short, factual description of a holiday. Only
  /// shown for events that carry a description (holidays); family events
  /// never reach here (they open the profile instead).
  void _showHolidayInfo(AppEvent event) {
    final description = event.description;
    if (description == null || description.isEmpty) return;
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final dateLabel = DateFormat('d MMMM', 'ru').format(event.date);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          key: const Key('holiday-info-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(event.icon, color: tokens.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      event.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontFamily: 'Lora',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${event.categoryLabel} · $dateLabel',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.inkMuted,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                description,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Center the placeholder, but scroll it if the remaining area below the
  // grid is short (small screens / landscape) so it never overflows.
  Widget _scrollSafeCenter(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _buildNoTree(ThemeData theme, RodnyaDesignTokens tokens) {
    return _scrollSafeCenter(
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_tree_outlined, size: 48, color: tokens.inkMuted),
            const SizedBox(height: 12),
            Text(
              'Выберите дерево',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'Lora',
                fontWeight: FontWeight.w700,
                color: tokens.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Чтобы увидеть даты семьи, выберите семейное дерево на главной.',
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: tokens.inkMuted),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('calendar-no-tree-cta'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('На главную'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme, RodnyaDesignTokens tokens) {
    return _scrollSafeCenter(
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: tokens.inkMuted),
            const SizedBox(height: 12),
            Text(
              'Не удалось загрузить',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'Lora',
                fontWeight: FontWeight.w700,
                color: tokens.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Проверьте соединение и попробуйте ещё раз.',
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: tokens.inkMuted),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('calendar-retry'),
              onPressed: () => _loadMonth(_focusedDay),
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayEmpty(ThemeData theme, RodnyaDesignTokens tokens) {
    return _scrollSafeCenter(
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'В этот день событий нет',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
