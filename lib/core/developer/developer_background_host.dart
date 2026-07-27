import 'dart:io';

import 'package:flutter/services.dart';

typedef DeveloperViewAvailabilityProvider =
    Future<DeveloperViewAvailability> Function();

const developerBackgroundNotificationMessageKeys = <String>{
  'platform.android.developer_service.channel_name',
  'platform.android.developer_service.channel_description',
  'platform.android.developer_service.title',
  'platform.android.developer_service.listening',
  'platform.android.developer_service.running',
};

typedef DeveloperBackgroundNotificationLocalizationProvider =
    DeveloperBackgroundNotificationLocalization? Function();

class DeveloperBackgroundNotificationLocalization {
  DeveloperBackgroundNotificationLocalization.fromAppMessages({
    required this.localeId,
    required Map<String, String> messages,
  }) : messages = Map.unmodifiable({
         for (final key in developerBackgroundNotificationMessageKeys)
           key: _requiredMessage(messages, key),
       });

  final String localeId;
  final Map<String, String> messages;

  Map<String, Object?> toChannelArguments({required int port}) => {
    'port': port,
    'localeId': localeId,
    'messages': messages,
  };

  static String _requiredMessage(Map<String, String> messages, String key) {
    final value = messages[key];
    if (value == null || value.isEmpty) {
      throw StateError('Missing Android developer notification message: $key');
    }
    return value;
  }
}

/// 需要真实 Android Activity/View 的开发操作当前是否可以执行。
class DeveloperViewAvailability {
  const DeveloperViewAvailability({
    required this.available,
    required this.reason,
    required this.activityAttached,
    required this.activityResumed,
    required this.windowFocused,
    required this.screenInteractive,
    required this.deviceLocked,
  });

  const DeveloperViewAvailability.available()
    : available = true,
      reason = 'foreground',
      activityAttached = true,
      activityResumed = true,
      windowFocused = true,
      screenInteractive = true,
      deviceLocked = false;

  final bool available;
  final String reason;
  final bool activityAttached;
  final bool activityResumed;
  final bool windowFocused;
  final bool screenInteractive;
  final bool deviceLocked;

  Map<String, Object?> toJson() => {
    'available': available,
    'reason': reason,
    'activityAttached': activityAttached,
    'activityResumed': activityResumed,
    'windowFocused': windowFocused,
    'screenInteractive': screenInteractive,
    'deviceLocked': deviceLocked,
  };

  factory DeveloperViewAvailability.fromJson(Map<Object?, Object?> json) {
    return DeveloperViewAvailability(
      available: json['available'] == true,
      reason: json['reason'] as String? ?? 'activity_unavailable',
      activityAttached: json['activityAttached'] == true,
      activityResumed: json['activityResumed'] == true,
      windowFocused: json['windowFocused'] == true,
      screenInteractive: json['screenInteractive'] == true,
      deviceLocked: json['deviceLocked'] == true,
    );
  }
}

abstract interface class DeveloperBackgroundHost {
  Future<void> start({
    required int port,
    DeveloperBackgroundNotificationLocalization? localization,
  });

  Future<void> updateNotification({
    required int port,
    required DeveloperBackgroundNotificationLocalization localization,
  });

  Future<void> stop();

  Future<DeveloperViewAvailability> viewAvailability();
}

/// Android 由前台服务提升进程优先级并持有当前 FlutterEngine。
///
/// 其他平台保持无操作；它们继续遵循各自现有的桌面或应用生命周期。
class PlatformDeveloperBackgroundHost implements DeveloperBackgroundHost {
  const PlatformDeveloperBackgroundHost();

  static const _channel = MethodChannel('playmesh/developer_background_host');

  bool get _isAndroid => Platform.isAndroid;

  @override
  Future<void> start({
    required int port,
    DeveloperBackgroundNotificationLocalization? localization,
  }) async {
    if (!_isAndroid) return;
    if (localization == null) {
      throw StateError(
        'android_developer_notification_localization_unavailable',
      );
    }
    await _channel.invokeMethod<void>(
      'start',
      localization.toChannelArguments(port: port),
    );
  }

  @override
  Future<void> updateNotification({
    required int port,
    required DeveloperBackgroundNotificationLocalization localization,
  }) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>(
      'updateNotification',
      localization.toChannelArguments(port: port),
    );
  }

  @override
  Future<void> stop() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<DeveloperViewAvailability> viewAvailability() async {
    if (!_isAndroid) return const DeveloperViewAvailability.available();
    final state = await _channel.invokeMapMethod<Object?, Object?>(
      'viewAvailability',
    );
    if (state == null) {
      return const DeveloperViewAvailability(
        available: false,
        reason: 'activity_unavailable',
        activityAttached: false,
        activityResumed: false,
        windowFocused: false,
        screenInteractive: false,
        deviceLocked: false,
      );
    }
    return DeveloperViewAvailability.fromJson(state);
  }
}

class DeveloperViewUnavailable implements Exception {
  const DeveloperViewUnavailable(this.availability);

  final DeveloperViewAvailability availability;

  String get message => switch (availability.reason) {
    'device_locked' => '设备已锁定，当前操作需要可见且可交互的 App 页面',
    'screen_off' => '屏幕已关闭，当前操作需要可见且可交互的 App 页面',
    'app_backgrounded' => 'App 当前位于后台，当前操作需要可见且可交互的页面',
    'window_not_focused' => 'App 窗口当前不可交互，当前操作需要获得窗口焦点',
    _ => '当前没有可用的 App Activity/View，无法执行该操作',
  };

  @override
  String toString() => message;
}
