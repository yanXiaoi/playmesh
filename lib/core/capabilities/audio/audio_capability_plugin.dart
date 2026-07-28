import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../capability_plugin.dart';

typedef AudioSpeechResultCallback =
    void Function(AudioSpeechRecognitionResult result);

abstract interface class AudioSpeechRecognitionEngine {
  bool get isListening;

  Future<bool> initialize({required void Function(Object error) onError});

  Future<void> listen({
    required String localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required void Function(double level) onSoundLevelChange,
    required AudioSpeechResultCallback onResult,
  });

  Future<void> stop();

  Future<void> cancel();
}

class NativeAudioSpeechRecognitionEngine
    implements AudioSpeechRecognitionEngine {
  NativeAudioSpeechRecognitionEngine({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> initialize({required void Function(Object error) onError}) {
    return _speech.initialize(onError: (error) => onError(error));
  }

  @override
  Future<void> listen({
    required String localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required void Function(double level) onSoundLevelChange,
    required AudioSpeechResultCallback onResult,
  }) async {
    await _speech.listen(
      onResult: (result) {
        onResult(AudioSpeechRecognitionResult.fromNative(result));
      },
      onSoundLevelChange: onSoundLevelChange,
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: listenFor,
        pauseFor: pauseFor,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

class AudioSpeechRecognitionAlternative {
  const AudioSpeechRecognitionAlternative({
    required this.recognizedWords,
    required this.recognizedPhrases,
    required this.confidence,
    required this.hasConfidenceRating,
  });

  final String recognizedWords;
  final List<String>? recognizedPhrases;
  final double confidence;
  final bool hasConfidenceRating;

  CapabilityJson toJson() => {
    'recognizedWords': recognizedWords,
    'recognizedPhrases': recognizedPhrases,
    'confidence': confidence,
    'hasConfidenceRating': hasConfidenceRating,
  };
}

class AudioSpeechRecognitionResult {
  const AudioSpeechRecognitionResult({
    required this.recognizedWords,
    required this.finalResult,
    required this.resultType,
    required this.confidence,
    required this.hasConfidenceRating,
    required this.alternates,
  });

  factory AudioSpeechRecognitionResult.fromNative(
    SpeechRecognitionResult result,
  ) {
    return AudioSpeechRecognitionResult(
      recognizedWords: result.recognizedWords,
      finalResult: result.finalResult,
      resultType: result.resultTypeValue.name,
      confidence: result.confidence,
      hasConfidenceRating: result.hasConfidenceRating,
      alternates: result.alternates
          .map(
            (alternative) => AudioSpeechRecognitionAlternative(
              recognizedWords: alternative.recognizedWords,
              recognizedPhrases: alternative.recognizedPhrases,
              confidence: alternative.confidence,
              hasConfidenceRating: alternative.hasConfidenceRating,
            ),
          )
          .toList(growable: false),
    );
  }

  final String recognizedWords;
  final bool finalResult;
  final String resultType;
  final double confidence;
  final bool hasConfidenceRating;
  final List<AudioSpeechRecognitionAlternative> alternates;

  CapabilityJson toJson() => {
    'recognizedWords': recognizedWords,
    'finalResult': finalResult,
    'resultType': resultType,
    'confidence': confidence,
    'hasConfidenceRating': hasConfidenceRating,
    'alternates': alternates
        .map((alternative) => alternative.toJson())
        .toList(growable: false),
  };
}

/// 音频能力独立承载 Web 麦克风声明与原生语音转文字。
class AudioCapabilityPlugin implements CapabilityPlugin {
  AudioCapabilityPlugin({AudioSpeechRecognitionEngine? speechEngine})
    : _speechEngine = speechEngine ?? NativeAudioSpeechRecognitionEngine();

  static const code = 'media.microphone';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '麦克风与语音转文字',
    description: '允许标准 Web API 使用麦克风，并提供跨平台原生语音转文字。',
    apiVersion: '1.1.0',
    optionsSchema: {'type': 'object', 'additionalProperties': false},
    methods: [
      CapabilityMethodDescriptor(
        name: 'toText',
        description: '按指定语言和时限启动一次短语音识别；listenFor、pauseFor 的单位为秒。',
        requiresUserActivation: true,
        argumentsSchema: {
          'type': 'object',
          'required': ['localeId', 'listenFor', 'pauseFor'],
          'properties': {
            'localeId': {'type': 'string', 'minLength': 1},
            'listenFor': {'type': 'integer', 'minimum': 1, 'maximum': 300},
            'pauseFor': {'type': 'integer', 'minimum': 1, 'maximum': 30},
          },
          'additionalProperties': false,
        },
        resultSchema: {
          'type': 'object',
          'required': ['started'],
          'properties': {
            'started': {'type': 'boolean'},
          },
          'additionalProperties': false,
        },
      ),
    ],
    events: [
      CapabilityEventDescriptor(
        name: 'textOnSoundLevelChange',
        description: '识别期间输入声音级别变化；level 由系统识别器提供，通常表示分贝值。',
        dataSchema: {
          'type': 'object',
          'required': ['level'],
          'properties': {
            'level': {'type': 'number'},
          },
          'additionalProperties': false,
        },
      ),
      CapabilityEventDescriptor(
        name: 'textOnResult',
        description: '返回语音识别的部分、中间或最终结果以及候选文本。',
        dataSchema: {
          'type': 'object',
          'required': [
            'recognizedWords',
            'finalResult',
            'resultType',
            'confidence',
            'hasConfidenceRating',
            'alternates',
          ],
          'properties': {
            'recognizedWords': {'type': 'string'},
            'finalResult': {'type': 'boolean'},
            'resultType': {
              'type': 'string',
              'enum': ['partial', 'intermediate', 'finalResult'],
            },
            'confidence': {'type': 'number'},
            'hasConfidenceRating': {'type': 'boolean'},
            'alternates': {
              'type': 'array',
              'items': {
                'type': 'object',
                'required': [
                  'recognizedWords',
                  'recognizedPhrases',
                  'confidence',
                  'hasConfidenceRating',
                ],
                'properties': {
                  'recognizedWords': {'type': 'string'},
                  'recognizedPhrases': {
                    'type': ['array', 'null'],
                    'items': {'type': 'string'},
                  },
                  'confidence': {'type': 'number'},
                  'hasConfidenceRating': {'type': 'boolean'},
                },
                'additionalProperties': false,
              },
            },
          },
          'additionalProperties': false,
        },
      ),
    ],
  );

  final AudioSpeechRecognitionEngine _speechEngine;
  _AudioCapabilityInstance? _activeInstance;
  bool _initialized = false;

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  bool get isAvailable {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    if (options.isNotEmpty) {
      throw const FormatException('音频能力不接受创建参数');
    }
    if (_activeInstance != null) {
      throw StateError('同一页面只能创建一个音频能力实例');
    }
    if (!isAvailable) throw UnsupportedError('当前平台不支持语音转文字');
    if (!_initialized) {
      final initialized = await _speechEngine.initialize(
        onError: (error) => _activeInstance?.addError(error),
      );
      if (!initialized) {
        throw UnsupportedError('当前设备的语音识别服务不可用或权限被拒绝');
      }
      _initialized = true;
    }
    late final _AudioCapabilityInstance instance;
    instance = _AudioCapabilityInstance(
      speechEngine: _speechEngine,
      onDisposed: () {
        if (identical(_activeInstance, instance)) {
          _activeInstance = null;
        }
      },
    );
    _activeInstance = instance;
    return instance;
  }

  @override
  Future<CapabilityJson> test(Duration timeout) async {
    if (!isAvailable) throw UnsupportedError('当前平台不支持语音转文字');
    return {
      'available': true,
      'permissionRequested': false,
      'methods': const ['toText'],
      'events': const ['textOnSoundLevelChange', 'textOnResult'],
    };
  }

  @override
  Future<void> dispose() async {
    await _activeInstance?.dispose();
  }
}

class _AudioCapabilityInstance implements CapabilityInstance {
  _AudioCapabilityInstance({
    required this.speechEngine,
    required this.onDisposed,
  });

  final AudioSpeechRecognitionEngine speechEngine;
  final void Function() onDisposed;
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async {
    if (_disposed) throw StateError('能力实例已释放');
    if (method != 'toText') {
      throw FormatException('音频能力不支持方法：$method');
    }
    if (arguments.keys.any(
      (key) => key != 'localeId' && key != 'listenFor' && key != 'pauseFor',
    )) {
      throw const FormatException('toText 包含未知参数');
    }
    final localeId = arguments['localeId'];
    final listenFor = arguments['listenFor'];
    final pauseFor = arguments['pauseFor'];
    if (localeId is! String || localeId.trim().isEmpty) {
      throw const FormatException('localeId 必须是非空字符串');
    }
    if (listenFor is! int || listenFor < 1 || listenFor > 300) {
      throw const FormatException('listenFor 必须是 1 至 300 的整数秒');
    }
    if (pauseFor is! int || pauseFor < 1 || pauseFor > 30) {
      throw const FormatException('pauseFor 必须是 1 至 30 的整数秒');
    }
    if (pauseFor > listenFor) {
      throw const FormatException('pauseFor 不能大于 listenFor');
    }
    if (speechEngine.isListening) {
      throw StateError('语音识别正在进行中');
    }
    await speechEngine.listen(
      localeId: localeId.trim(),
      listenFor: Duration(seconds: listenFor),
      pauseFor: Duration(seconds: pauseFor),
      onSoundLevelChange: (level) {
        if (_disposed) return;
        _events.add(
          CapabilityInstanceEvent('textOnSoundLevelChange', {'level': level}),
        );
      },
      onResult: (result) {
        if (_disposed) return;
        _events.add(CapabilityInstanceEvent('textOnResult', result.toJson()));
      },
    );
    if (!speechEngine.isListening) {
      throw StateError('语音识别未能启动');
    }
    return {'started': true};
  }

  void addError(Object error) {
    if (_disposed) return;
    _events.addError(error);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (speechEngine.isListening) {
      await speechEngine.cancel();
    }
    onDisposed();
    await _events.close();
  }
}
