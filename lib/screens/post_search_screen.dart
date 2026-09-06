import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/post_service_interface.dart';
import '../models/post.dart';
import '../theme/app_theme.dart';
import '../widgets/post_card.dart';
import '../widgets/post_card_shimmer.dart';

/// Substring search across post content + author name within the
/// active tree. Backend tokenises the query (Russian-locale lowercase,
/// up to 8 terms) and AND-matches against the post haystack — so
/// "детский сад" only finds posts containing both terms.
///
/// Debounced 320ms while typing so each keystroke doesn't hammer the
/// API. Empty input and no-results both render the compact one-line
/// [_SearchHint] below (density chunk 25) — не общий EmptyStateWidget.
class PostSearchScreen extends StatefulWidget {
  const PostSearchScreen({super.key});

  @override
  State<PostSearchScreen> createState() => _PostSearchScreenState();
}

class _PostSearchScreenState extends State<PostSearchScreen> {
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  Object? _error;
  List<Post> _results = const <Post>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = const <Post>[];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () {
      _runSearch(trimmed);
    });
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Audience-mode search: hit the index across every branch
      // the viewer belongs to instead of narrowing to the active
      // BranchSwitcher selection. Mirror of the home feed default
      // — for the same reason: typing «свадьба» should find the
      // post regardless of which branch the user happens to have
      // selected when they remembered they wanted to look it up.
      final posts = await _postService.searchPosts(
        query: query,
      );
      if (!mounted || _query.trim() != query) return;
      setState(() {
        _results = posts;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      backgroundColor: tokens.bgBase,
      appBar: AppBar(
        backgroundColor: tokens.bgBase,
        elevation: 0,
        titleSpacing: 0,
        // Плотность (чанк 25): поле поиска — пилюля 50dp в топбаре
        // (было — голый TextField без рамки на всю высоту AppBar, крестик
        // вынесен в actions отдельной кнопкой). Стало — иконка + текст +
        // встроенный крестик в одной строке, тач-цель крестика 44dp.
        title: Container(
          key: const Key('post-search-box'),
          height: 50,
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: tokens.inkSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('post-search-field'),
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: _onChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Поиск по постам',
                    border: InputBorder.none,
                    isDense: true,
                    isCollapsed: true,
                    hintStyle: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      color: tokens.inkSecondary,
                    ),
                  ),
                  style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16),
                ),
              ),
              if (_query.isNotEmpty)
                SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    key: const Key('post-search-clear'),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Очистить',
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _buildBody(theme, tokens),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, RodnyaDesignTokens tokens) {
    // Плотность (чанк 25): «пустые» состояния поиска были общим
    // EmptyStateWidget — карточка-в-карточке (GlassPanel) с крупной
    // круглой иконкой, центрированная в половину экрана. EmptyStateWidget
    // общий на несколько экранов (comment_sheet, profile) — трогать его
    // здесь не стал; вместо этого свой компактный _SearchHint только для
    // этого экрана: иконка + строка текста, ≤56dp.
    if (_query.trim().isEmpty) {
      return const _SearchHint(
        key: Key('post-search-hint'),
        icon: Icons.search,
        text: 'Введите слово из поста или имя автора — например «свадьба»',
      );
    }
    if (_loading && _results.isEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: 3,
        itemBuilder: (_, __) => const PostCardShimmer(),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: tokens.inkSecondary),
            const SizedBox(height: 10),
            Text(
              'Не удалось выполнить поиск: $_error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                color: tokens.inkSecondary,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: FilledButton.tonalIcon(
                onPressed: () => _runSearch(_query.trim()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Повторить'),
              ),
            ),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return const _SearchHint(
        key: Key('post-search-empty'),
        icon: Icons.search_off,
        text: 'Ничего не нашли — попробуйте другое слово',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        return PostCard(post: _results[index]);
      },
    );
  }
}

/// Плотность (чанк 25): компактная строка-подсказка вместо
/// EmptyStateWidget (карточка на пол-экрана) — иконка + текст в один
/// ряд, ≤56dp, как «плашки» в остальных местах приложения.
class _SearchHint extends StatelessWidget {
  const _SearchHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Фиксированная высота (не intrinsic по тексту) — контейнер строго
    // одна строка ≤56dp независимо от ширины шрифта; текст обрезается
    // многоточием, если не помещается (harness fallback-шрифт шире
    // Manrope — see CLAUDE.md).
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
