// Shared popup presentation: every dialog in the app opens the same way.
//
// [showAppDialog] is a drop-in replacement for Flutter's showDialog with the
// app's motion: a fade plus a subtle scale from 0.96 (AppMotion.popup in,
// AppMotion.popupExit out, decelerating, no bounce). With the system's
// reduced-motion setting it appears and disappears without animation.
// Behaviour (barrier taps, Escape, focus trapping, results) is Flutter's own.
import 'package:flutter/material.dart';

import 'design_tokens.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
}) {
  final reduced = AppMotion.reduced(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior: traversalEdgeBehavior,
    animationStyle: AnimationStyle(
      duration: reduced ? Duration.zero : AppMotion.popup,
      reverseDuration: reduced ? Duration.zero : AppMotion.popupExit,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.exit,
    ),
    builder: (context) => PopupEntrance(child: builder(context)),
  );
}

/// Scales its child from [AppMotion.popupScaleFrom] to 1 with the enclosing
/// route's animation (the route itself fades). Outside a route, or with
/// reduced motion, it just shows the child.
class PopupEntrance extends StatelessWidget {
  const PopupEntrance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || AppMotion.reduced(context)) return child;
    return ScaleTransition(
      scale: Tween(begin: AppMotion.popupScaleFrom, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
          reverseCurve: AppMotion.exit,
        ),
      ),
      child: child,
    );
  }
}
