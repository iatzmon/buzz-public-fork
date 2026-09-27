import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../theme/theme.dart';

/// Keeps the workspace list and detail navigator mounted across window changes.
///
/// Wide windows show both panes. Compact windows show the list until a detail
/// is opened. Resizing changes only pane geometry, never the route stack.
class AdaptiveWorkspace extends HookConsumerWidget {
  const AdaptiveWorkspace({super.key, required this.child});

  final Widget child;

  /// Opens a fresh detail stack, or uses normal navigation outside the shell.
  static Future<T?> open<T>(BuildContext context, Route<T> route) {
    final scope = context.dependOnInheritedWidgetOfExactType<_WorkspaceScope>();
    if (scope == null) return Navigator.of(context).push(route);
    FocusManager.instance.primaryFocus?.unfocus();
    return scope.navigatorKey.currentState!.pushAndRemoveUntil(
      route,
      (route) => route.isFirst,
    );
  }

  /// Observer for controls whose lifecycle follows the enclosing detail route.
  static RouteObserver<ModalRoute<void>>? routeObserverOf(
    BuildContext context,
  ) => context.dependOnInheritedWidgetOfExactType<_WorkspaceScope>()?.observer;

  /// Root route that can cover the whole workspace with a utility page.
  static ModalRoute<void>? rootRouteOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkspaceScope>()?.rootRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigatorKey = useMemoized(GlobalKey<NavigatorState>.new);
    final hasDetail = useState(false);
    // Layout-only preferences survive folding and hiding without owning routes.
    final preferredListWidth = useState<double?>(null);
    final sidebarCollapsed = useState(false);
    final overlayOpen = useState<bool?>(null);
    final observer = useMemoized(
      () => _DetailObserver(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            hasDetail.value = navigatorKey.currentState?.canPop() ?? false;
            overlayOpen.value = null;
          }
        });
      }),
    );
    final media = MediaQuery.of(context);

    return _WorkspaceScope(
      navigatorKey: navigatorKey,
      observer: observer,
      rootRoute: ModalRoute.of(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final window = Offset.zero & constraints.biggest;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          var usable = window;
          Rect? leftOfHinge;
          Rect? rightOfHinge;
          for (final feature in media.displayFeatures) {
            if (feature.type != DisplayFeatureType.hinge &&
                feature.state != DisplayFeatureState.postureHalfOpened) {
              continue;
            }
            final bounds = feature.bounds.intersect(window);
            if (bounds.top <= window.top && bounds.bottom >= window.bottom) {
              final left = Rect.fromLTRB(0, 0, bounds.left, window.bottom);
              final right = Rect.fromLTRB(
                bounds.right,
                0,
                window.right,
                window.bottom,
              );
              if (left.width >= (rtl ? 360 : 320) &&
                  right.width >= (rtl ? 320 : 360)) {
                leftOfHinge = left;
                rightOfHinge = right;
              } else {
                usable = left.width >= right.width ? left : right;
              }
              break;
            }
            if (bounds.left <= window.left && bounds.right >= window.right) {
              final top = Rect.fromLTRB(0, 0, window.right, bounds.top);
              final bottom = Rect.fromLTRB(
                0,
                bounds.bottom,
                window.right,
                window.bottom,
              );
              usable = top.height >= bottom.height ? top : bottom;
              break;
            }
          }
          final expanded = leftOfHinge != null || usable.width >= 720;
          // Narrow tablets keep a full-width conversation behind a bounded menu.
          final overlay = !expanded && usable == window && usable.width >= 600;
          final menuOpen = overlay && (overlayOpen.value ?? !hasDetail.value);
          final collapsed = overlay ? !menuOpen : sidebarCollapsed.value;
          const controlsWidth = 48.0;
          final maximumListWidth = (usable.width - controlsWidth - 320).clamp(
            320.0,
            560.0,
          );
          final defaultListWidth = (usable.width * .36).clamp(320.0, 360.0);
          final listWidth = (preferredListWidth.value ?? defaultListWidth)
              .clamp(320.0, maximumListWidth);
          final listRect = !expanded && !overlay
              ? usable
              : leftOfHinge != null
              ? (rtl ? rightOfHinge! : leftOfHinge)
              : Rect.fromLTWH(
                  rtl
                      ? usable.right - (overlay ? 320 : listWidth)
                      : usable.left,
                  usable.top,
                  overlay ? 320 : listWidth,
                  usable.height,
                );
          final physicalDetail = rightOfHinge == null
              ? usable
              : (rtl ? leftOfHinge! : rightOfHinge);
          final controlsLeft = rightOfHinge != null || collapsed
              ? (rtl
                    ? physicalDetail.right - controlsWidth
                    : physicalDetail.left)
              : (rtl ? listRect.left - controlsWidth : listRect.right);
          final controlsRect = Rect.fromLTWH(
            controlsLeft,
            usable.top,
            controlsWidth,
            usable.height,
          );
          final detailRect = overlay
              ? Rect.fromLTRB(
                  rtl ? usable.left : usable.left + controlsWidth,
                  usable.top,
                  rtl ? usable.right - controlsWidth : usable.right,
                  usable.bottom,
                )
              : !expanded
              ? usable
              : Rect.fromLTRB(
                  rtl ? physicalDetail.left : controlsRect.right,
                  usable.top,
                  rtl ? controlsRect.left : physicalDetail.right,
                  usable.bottom,
                );
          void resizeSidebar(double delta) {
            final currentWidth = (preferredListWidth.value ?? listWidth).clamp(
              320.0,
              maximumListWidth,
            );
            preferredListWidth.value = (currentWidth + delta).clamp(
              320.0,
              maximumListWidth,
            );
          }

          Widget pane(
            Rect rect,
            bool visible,
            String name,
            Widget child,
          ) => Positioned.fromRect(
            key: ValueKey('pane-$name'),
            rect: rect,
            child: Offstage(
              offstage: !visible,
              child: TickerMode(
                enabled: visible,
                child: ClipRect(
                  child: MediaQuery(
                    data: media
                        .removeDisplayFeatures(rect)
                        .copyWith(
                          size: rect.size,
                          displayFeatures: [
                            for (final feature in media.displayFeatures)
                              if (rect.overlaps(feature.bounds))
                                DisplayFeature(
                                  bounds: feature.bounds.shift(-rect.topLeft),
                                  type: feature.type,
                                  state: feature.state,
                                ),
                          ],
                        ),
                    child: FocusScope(
                      canRequestFocus:
                          visible &&
                          !(overlay && menuOpen && name == 'workspace-detail'),
                      child: KeyedSubtree(key: ValueKey(name), child: child),
                    ),
                  ),
                ),
              ),
            ),
          );

          return PopScope<Object?>(
            canPop: !menuOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && menuOpen) overlayOpen.value = false;
            },
            child: ColoredBox(
              color: context.colors.outlineVariant,
              child: Stack(
                children: [
                  pane(
                    detailRect,
                    expanded || overlay || hasDetail.value,
                    'workspace-detail',
                    NavigatorPopHandler<Object?>(
                      enabled: !menuOpen,
                      onPopWithResult: (result) {
                        if (!menuOpen) {
                          unawaited(
                            navigatorKey.currentState!.maybePop(result),
                          );
                        }
                      },
                      child: Navigator(
                        key: navigatorKey,
                        observers: [observer],
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (context) => Scaffold(
                            body: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(Grid.gutter),
                                child: Text(
                                  'Select a conversation',
                                  style: context.textTheme.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (menuOpen)
                    Positioned.fromRect(
                      rect: usable,
                      child: ModalBarrier(
                        color: Colors.black26,
                        onDismiss: () => overlayOpen.value = false,
                        semanticsLabel: 'Dismiss sidebar',
                      ),
                    ),
                  pane(
                    listRect,
                    overlay
                        ? menuOpen
                        : expanded
                        ? !collapsed
                        : !hasDetail.value,
                    'workspace-list',
                    child,
                  ),
                  if (expanded || overlay)
                    pane(
                      controlsRect,
                      true,
                      'workspace-controls',
                      _WorkspaceControls(
                        collapsed: collapsed,
                        onToggle: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          if (overlay) {
                            overlayOpen.value = !menuOpen;
                          } else {
                            sidebarCollapsed.value = !collapsed;
                          }
                        },
                        width: listWidth,
                        maximumWidth: maximumListWidth,
                        onResize: expanded && !collapsed && leftOfHinge == null
                            ? resizeSidebar
                            : null,
                        onReset: () => preferredListWidth.value = null,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WorkspaceScope extends InheritedWidget {
  const _WorkspaceScope({
    required this.navigatorKey,
    required this.observer,
    required this.rootRoute,
    required super.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final RouteObserver<ModalRoute<void>> observer;
  final ModalRoute<void>? rootRoute;

  @override
  bool updateShouldNotify(_WorkspaceScope oldWidget) =>
      navigatorKey != oldWidget.navigatorKey ||
      observer != oldWidget.observer ||
      rootRoute != oldWidget.rootRoute;
}

class _DetailObserver extends RouteObserver<ModalRoute<void>> {
  _DetailObserver(this.onChanged);
  final VoidCallback onChanged;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    super.didChangeTop(topRoute, previousTopRoute);
    onChanged();
  }
}

class _WorkspaceControls extends HookConsumerWidget {
  const _WorkspaceControls({
    required this.collapsed,
    required this.onToggle,
    required this.width,
    required this.maximumWidth,
    required this.onResize,
    required this.onReset,
  });

  final bool collapsed;
  final VoidCallback onToggle;
  final double width;
  final double maximumWidth;
  final ValueChanged<double>? onResize;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final focusNode = useFocusNode();
    final focused = useState(false);
    final colors = context.colors;
    final delta = rtl ? -24.0 : 24.0;
    final handle = onResize;
    return Material(
      color: colors.surface,
      child: SafeArea(
        child: Column(
          children: [
            IconButton(
              key: const ValueKey('workspace-sidebar-toggle'),
              tooltip: collapsed ? 'Show sidebar' : 'Hide sidebar',
              onPressed: onToggle,
              icon: Icon(
                collapsed
                    ? (rtl
                          ? LucideIcons.panelRightOpen
                          : LucideIcons.panelLeftOpen)
                    : (rtl
                          ? LucideIcons.panelRightClose
                          : LucideIcons.panelLeftClose),
              ),
            ),
            if (handle != null)
              Expanded(
                child: Semantics(
                  label: 'Resize sidebar',
                  slider: true,
                  value: '${width.round()} pixels',
                  increasedValue:
                      '${(width + 24).clamp(320, maximumWidth).round()} pixels',
                  decreasedValue:
                      '${(width - 24).clamp(320, maximumWidth).round()} pixels',
                  onIncrease: width < maximumWidth ? () => handle(24) : null,
                  onDecrease: width > 320 ? () => handle(-24) : null,
                  child: ExcludeSemantics(
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.arrowLeft,
                        ): () =>
                            handle(-delta),
                        const SingleActivator(
                          LogicalKeyboardKey.arrowRight,
                        ): () =>
                            handle(delta),
                        const SingleActivator(LogicalKeyboardKey.home): onReset,
                      },
                      child: Focus(
                        focusNode: focusNode,
                        onFocusChange: (value) => focused.value = value,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            key: const ValueKey('workspace-sidebar-divider'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (_) =>
                                focusNode.requestFocus(),
                            onHorizontalDragUpdate: (event) =>
                                handle(event.delta.dx * (rtl ? -1 : 1)),
                            onDoubleTap: onReset,
                            child: Tooltip(
                              message:
                                  'Drag to resize sidebar. Double-tap to reset.',
                              excludeFromSemantics: true,
                              child: SizedBox.expand(
                                child: Center(
                                  child: Container(
                                    width: focused.value ? 6 : 4,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: focused.value
                                          ? colors.primary
                                          : colors.outlineVariant,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
