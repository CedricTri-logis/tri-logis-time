import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tracking/providers/gps_health_guard_provider.dart';

/// NavigatorObserver that fires a soft GPS health nudge on every screen navigation.
class GpsHealthNavigatorObserver extends NavigatorObserver {
  final WidgetRef _ref;

  GpsHealthNavigatorObserver(this._ref);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    nudgeGpsFromWidget(_ref, source: 'navigation');
  }
}
