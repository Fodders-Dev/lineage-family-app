part of 'interactive_family_tree.dart';

extension _InteractiveFamilyTreeSections on _InteractiveFamilyTreeState {
  Widget _buildInteractiveTreeSurface({
    required BuildContext context,
    required double stackWidth,
    required double stackHeight,
    required double interactionBoundary,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _syncViewportSize(Size(constraints.maxWidth, constraints.maxHeight));

          return Stack(
            key: const Key('interactive-family-tree-viewport'),
            // The canvas itself may pan beyond its viewport, but it must never
            // paint over the screen app bar, reassurance banner, or the
            // List/Tree switcher above this widget. InteractiveViewer keeps
            // Clip.none so panning remains fluid inside the viewport; this
            // outer boundary contains the rendered graph to its own surface.
            clipBehavior: Clip.hardEdge,
            children: [
              ClipRect(
                key: const Key('interactive-family-tree-canvas-clip'),
                child: _buildInteractiveCanvas(
                  stackWidth: stackWidth,
                  stackHeight: stackHeight,
                  interactionBoundary: interactionBoundary,
                ),
              ),
              // Position canvas-internal overlays below the floating chrome
              // (toolbar + sidebar context column on mobile). The chrome
              // height is captured by `viewportReservedTop`; we sit the
              // overlay just under it so it never lives under the
              // toolbar pill.
              Positioned(
                right: 12,
                top: widget.viewportReservedTop > 96
                    ? widget.viewportReservedTop + 8
                    : 92,
                child: _buildViewportControlDock(),
              ),
              // Blank-card creator FAB on the LEFT (mirrors the
              // viewport control dock on the right). Visible only
              // when the host wired `onAddBlankPerson` — the public
              // viewer doesn't, so the canvas there stays read-only.
              if (widget.onAddBlankPerson != null && !widget.isEditMode)
                Positioned(
                  left: 12,
                  top: widget.viewportReservedTop > 96
                      ? widget.viewportReservedTop + 8
                      : 92,
                  child: _buildBlankCardCreatorFab(),
                ),
              // Small unobtrusive zoom indicator at the BOTTOM of the
              // canvas — replaces the previous "Семья / 250%" pill at
              // the top-left which the user said was overpowering.
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: IgnorePointer(
                  child: Center(child: _buildBottomZoomIndicator()),
                ),
              ),
              // Edge-first connector status pill — appears at the top
              // center when the user has long-pressed a card and is
              // mid-drag. Stays visible until they drop on a target
              // (picker fires) or cancel via the X / ESC / tap-empty.
              if (_isConnecting || _showingRelationPicker)
                Positioned(
                  left: 0,
                  right: 0,
                  top: widget.viewportReservedTop > 8
                      ? widget.viewportReservedTop - 4
                      : 16,
                  child: Center(child: _buildConnectingPill()),
                ),
              // L (lost-user recovery): floating pill shown only when the tree
              // has drifted fully off the viewport. Tap fits it back into view.
              // Sits just above the bottom zoom indicator so they don't collide.
              if (_treeOffscreen)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 56,
                  child: Center(child: _buildReturnToTreePill()),
                ),
            ],
          );
        },
      ),
    );
  }

  void _syncViewportSize(Size viewportSize) {
    if (_viewportSize == viewportSize) {
      return;
    }
    _viewportSize = viewportSize;
    _hasAppliedViewportFit = false;
    _scheduleViewportFit();
  }

  Widget _buildInteractiveCanvas({
    required double stackWidth,
    required double stackHeight,
    required double interactionBoundary,
  }) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.equal): () => _zoomBy(1.2),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): () => _zoomBy(1.2),
        const SingleActivator(LogicalKeyboardKey.minus): () => _zoomBy(1 / 1.2),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): () =>
            _zoomBy(1 / 1.2),
        const SingleActivator(LogicalKeyboardKey.digit0): () =>
            _fitTreeToViewport(),
        // ESC cancels an in-progress connect drag on desktop. The
        // binding is always installed but is a no-op when not in
        // connect mode — _cancelConnecting short-circuits.
        const SingleActivator(LogicalKeyboardKey.escape): _cancelConnecting,
      },
      child: Focus(
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Tap on empty canvas cancels an in-progress connect.
          // Cards have their own onTap that runs first, so tapping
          // a card during connect doesn't reach this handler.
          onTap: _isConnecting ? _cancelConnecting : null,
          // UX-аудит P1: double-tap = зум к точке (карты/Figma), а не
          // «вписать всё» — fit остаётся на кнопке дока и клавише 0.
          // Позиция приходит в onDoubleTapDown (второй тап, down).
          onDoubleTapDown: (details) =>
              _doubleTapLocalPosition = details.localPosition,
          onDoubleTap: _handleCanvasDoubleTap,
          // Lasso (selection-mode only). Drag-on-empty paints a
          // rectangle that gathers every overlapping card into the
          // host's selection set on release. When NOT in selection
          // mode these handlers are null and InteractiveViewer's
          // pan keeps owning the gesture.
          onPanStart: _isSelectionLassoEnabled ? _handleLassoStart : null,
          onPanUpdate: _isSelectionLassoEnabled ? _handleLassoUpdate : null,
          onPanEnd: _isSelectionLassoEnabled ? _handleLassoEnd : null,
          onPanCancel: _isSelectionLassoEnabled ? _handleLassoCancel : null,
          child: InteractiveViewer(
            transformationController: _transformationController,
            constrained: false,
            clipBehavior: Clip.none,
            boundaryMargin: EdgeInsets.all(interactionBoundary),
            panAxis: PanAxis.free,
            // Pan disabled in selection mode (lasso owns drag) and
            // during connect-drag (LongPressDraggable owns it).
            // Otherwise the standard "drag to pan" works as before.
            panEnabled: _draggingPersonId == null &&
                !_isConnecting &&
                !_isSelectionLassoEnabled,
            scaleEnabled: true,
            trackpadScrollCausesScale: true,
            minScale: 0.08,
            maxScale: 3.5,
            child: _buildTreeContent(
              stackWidth: stackWidth,
              stackHeight: stackHeight,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeContent({
    required double stackWidth,
    required double stackHeight,
  }) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final stackContent = Stack(
      clipBehavior: Clip.none,
      children: [
        if (widget.showGenerationGuides)
          ..._buildGenerationGuideWidgets(stackWidth: stackWidth),
        CustomPaint(
          size: Size(stackWidth, stackHeight),
          painter: FamilyTreePainter(
            nodePositions,
            connections,
            graphSnapshot: widget.graphSnapshot,
            relations: widget.relations,
            lineColor: tokens.inkSecondary,
            mutedLineColor: tokens.inkMuted,
            spouseColor: tokens.warm,
            junctionColor: tokens.inkSecondary,
            // Phase 4 chunk 3c: cross-tree edge tint.
            // foreignPersonIds = empty Set когда flag=false либо mine
            // mode → painter всегда выбирает legacy warm paints
            // (bit-identical legacy).
            foreignEdgeColor: tokens.edgeForeignTint,
            foreignPersonIds: _foreignPersonIds,
          ),
        ),
        if ((widget.selectedPersonId ?? '').isNotEmpty)
          CustomPaint(
            size: Size(stackWidth, stackHeight),
            painter: _SelectedTreePathPainter(
              nodePositions: nodePositions,
              relations: widget.relations,
              selectedPersonId: widget.selectedPersonId!,
              // Reference uses accent (deep teal/green) for active path
              // highlights — switch from warm so it reads as "selected"
              // rather than "warning".
              accent: tokens.accent,
            ),
          ),
        // Edge-first connector: live preview line from the long-pressed
        // source card to the current pointer position. Painted ABOVE
        // the existing relation lines so it's visible even when the
        // pointer crosses an established edge.
        if (_isConnecting &&
            _connectingFromPersonId != null &&
            _connectingPointerCanvasPosition != null &&
            nodePositions[_connectingFromPersonId!] != null)
          IgnorePointer(
            child: CustomPaint(
              size: Size(stackWidth, stackHeight),
              painter: _ConnectorPreviewPainter(
                source: nodePositions[_connectingFromPersonId!]!,
                target: _connectingPointerCanvasPosition!,
                color: tokens.accent,
              ),
            ),
          ),
        // Lasso rectangle while the user drags in selection mode.
        // IgnorePointer so the rectangle never swallows pointer
        // events from cards underneath — painting only.
        if (_lassoStartCanvas != null && _lassoCurrentCanvas != null)
          IgnorePointer(
            child: CustomPaint(
              size: Size(stackWidth, stackHeight),
              painter: _LassoRectPainter(
                start: _lassoStartCanvas!,
                end: _lassoCurrentCanvas!,
                accent: tokens.accent,
              ),
            ),
          ),
        ..._buildPersonWidgets(),
        if (widget.isEditMode && widget.showInlineEditPanel)
          _buildInlineEditPanel(
            stackWidth: stackWidth,
            stackHeight: stackHeight,
          ),
      ],
    );

    // Listener tracks pointer-move events in the canvas's local
    // coordinate system (the same space `nodePositions` lives in,
    // because the Listener sits as a direct child of the
    // SizedBox the layout engine fills). When NOT connecting we
    // cheaply ignore the events; only the active drag updates
    // state, which keeps idle-canvas frame rates clean.
    return SizedBox(
      width: stackWidth,
      height: stackHeight,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (event) {
          if (!_isConnecting) return;
          // event.localPosition is in this Listener's local coords,
          // which IS the canvas-local coordinate space for our
          // overlay painter — no further transform needed.
          if (_connectingPointerCanvasPosition != event.localPosition) {
            _updateTreeState(() {
              _connectingPointerCanvasPosition = event.localPosition;
            });
          }
        },
        child: stackContent,
      ),
    );
  }

  // Top-of-canvas pill shown while a connect drag is in flight or
  // the relation-type picker is open. Tap the X to abort.
  // L (lost-user recovery): the «Вернуться к дереву» pill. Tappable (NOT
  // wrapped in IgnorePointer, unlike the zoom HUD) → _fitTreeToViewport().
  Widget _buildReturnToTreePill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _fitTreeToViewport,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.filter_center_focus,
                color: scheme.onPrimary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Вернуться к дереву',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectingPill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sourcePerson = _connectingFromPersonId == null
        ? null
        : _findPersonInData(_connectingFromPersonId!);
    final sourceName = sourcePerson?.displayName ?? 'этого человека';
    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cable_rounded, color: scheme.onPrimary, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Перетащите «$sourceName» на другую карточку',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: 'Отменить (Esc)',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _cancelConnecting,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    color: scheme.onPrimary,
                    size: 18,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Transient zoom HUD at the bottom of the canvas (audit #16/#20).
  /// Shows «80%» on pinch / zoom buttons and «Вписано» / «Центрировано»
  /// on the fit / center actions, then fades after ~1s — so the user
  /// gets feedback that a zoom/center happened without a pill sitting
  /// there permanently. Driven by `_zoomHudVisible` / `_zoomHudText`.
  Widget _buildBottomZoomIndicator() {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return AnimatedOpacity(
      opacity: _zoomHudVisible ? 1.0 : 0.0,
      duration: Duration(milliseconds: _zoomHudVisible ? 120 : 260),
      curve: Curves.easeOut,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: tokens.surfaceStrong.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: tokens.surfaceLine.withValues(alpha: 0.6),
            width: 0.6,
          ),
        ),
        child: Text(
          _zoomHudText,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: tokens.inkSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
                fontSize: 11,
              ),
        ),
      ),
    );
  }

  Widget _buildViewportControlDock() {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final currentUserNodeId = _findCurrentUserNodeId();
    final branchRootPersonId = widget.branchRootPersonId;

    // Collapsed state: single chevron-pill that expands on tap. This
    // way the dock doesn't overlap person cards by default — the
    // canvas stays clean. Tap the chevron → animated expand to the
    // full vertical button column. Tap the close pill → collapse
    // back. Same TG / Maps "tools FAB" pattern.
    final expanded = _controlDockExpanded;
    final collapsedToggle = Tooltip(
      message: 'Настройки вида',
      child: Material(
        color: tokens.surfaceStrong.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 1.5,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _setControlDockExpanded(!expanded),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              expanded ? Icons.close_rounded : Icons.tune_rounded,
              size: 20,
              color: tokens.accentStrong,
            ),
          ),
        ),
      ),
    );

    if (!expanded) {
      return collapsedToggle;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: tokens.surfaceStrong.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          border: Border.all(
            color: tokens.surfaceLine.withValues(alpha: 0.9),
          ),
          boxShadow: tokens.panelShadow(
            Theme.of(context).brightness,
            floating: true,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDockButton(
              icon: Icons.close_rounded,
              tooltip: 'Свернуть',
              onPressed: () => _setControlDockExpanded(false),
            ),
            const SizedBox(height: 4),
            _buildDockButton(
              icon: Icons.add,
              tooltip: 'Увеличить',
              onPressed: () => _zoomBy(1.2),
            ),
            const SizedBox(height: 4),
            _buildDockButton(
              icon: Icons.remove,
              tooltip: 'Уменьшить',
              onPressed: () => _zoomBy(1 / 1.2),
            ),
            const SizedBox(height: 4),
            _buildDockButton(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Вписать дерево',
              onPressed: _fitTreeToViewport,
            ),
            if (currentUserNodeId != null) ...[
              const SizedBox(height: 4),
              _buildDockButton(
                icon: Icons.my_location_outlined,
                tooltip: 'Ко мне',
                onPressed: () => _focusOnPerson(currentUserNodeId),
              ),
            ],
            if (branchRootPersonId != null &&
                branchRootPersonId.isNotEmpty) ...[
              const SizedBox(height: 4),
              _buildDockButton(
                icon: Icons.alt_route_outlined,
                tooltip: widget.showGenerationGuides ? 'К ветке' : 'К кругу',
                onPressed: () => _focusOnPerson(branchRootPersonId),
              ),
              if (widget.onBranchFocusCleared != null) ...[
                const SizedBox(height: 4),
                _buildDockButton(
                  icon: Icons.clear_all,
                  tooltip: widget.showGenerationGuides
                      ? 'Сбросить ветку'
                      : 'Сбросить круг',
                  onPressed: widget.onBranchFocusCleared!,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDockButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: tokens.surface.withValues(alpha: 0.96),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          // Tighter button — was 44dp which made the vertical dock
          // ~280dp tall on mobile and overlapped person cards. 38dp
          // satisfies Android's 36dp tap-target floor + reads as a
          // quick action pill rather than a full FAB.
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 18, color: tokens.accentStrong),
          ),
        ),
      ),
    );
  }

  // Floating blank-card creator. Tap → small dialog with name +
  // gender + optional photo. Save → callback fires with a map the
  // host pipes to family_tree_service.addRelative(...). The new
  // person lands on the canvas with no relations; the user then
  // uses the edge-first connector (long-press → drag → drop) to
  // attach it to the rest of the tree.
  //
  // Distinct from the per-card "+" badge that appears on hover/
  // select: that one opens the legacy form-based quick-add sheet
  // and creates BOTH person + relation in one shot. This FAB
  // creates JUST the person — relations are added later via the
  // graphical connector.
  Widget _buildBlankCardCreatorFab() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Tooltip(
      message: 'Добавить карточку',
      child: Material(
        color: tokens.accent,
        borderRadius: BorderRadius.circular(999),
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _openBlankCardDialog,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              Icons.person_add_alt_1_rounded,
              size: 22,
              color: tokens.accentInk,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBlankCardDialog() async {
    final handler = widget.onAddBlankPerson;
    if (handler == null) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (dialogContext) => const _BlankCardDialog(),
    );
    if (result == null || !mounted) return;
    try {
      await handler(result);
    } catch (_) {
      // Host shows its own snackbar on failure; we don't need to
      // do anything here. Surfacing a second toast would compete.
    }
  }
}
