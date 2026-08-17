import 'dart:async';

import 'package:flutter/material.dart';

import 'developer_workspace_page.dart';

/// Reuses the existing in-App GDevelop route instead of constructing a second
/// WebView that would contend for the process-wide editor lease.
class GDevelopWorkspaceRouteCoordinator {
  Route<void>? _activeRoute;
  NavigatorState? _activeNavigator;

  Future<void> open({
    required BuildContext context,
    required Uri workspaceUri,
    required String title,
  }) {
    final navigator = Navigator.of(context);
    final active = _activeRoute;
    if (active != null &&
        active.isActive &&
        identical(_activeNavigator, navigator)) {
      navigator.popUntil((route) => identical(route, active));
      return Future<void>.value();
    }

    late final MaterialPageRoute<void> route;
    route = MaterialPageRoute<void>(
      builder: (_) => DeveloperWorkspacePage(
        workspaceUri: workspaceUri,
        workspaceTitle: title,
        isGDevelopWorkspace: true,
      ),
    );
    _activeRoute = route;
    _activeNavigator = navigator;
    unawaited(
      navigator.push<void>(route).whenComplete(() {
        if (identical(_activeRoute, route)) {
          _activeRoute = null;
          _activeNavigator = null;
        }
      }),
    );
    return Future<void>.value();
  }
}

final GDevelopWorkspaceRouteCoordinator gdevelopWorkspaceRouteCoordinator =
    GDevelopWorkspaceRouteCoordinator();
