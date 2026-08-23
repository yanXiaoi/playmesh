import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/audio/audio_capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_plugin.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('音频插件公开完整语音转文字契约', () {
    final descriptor = AudioCapabilityPlugin.capabilityDescriptor;

    expect(descriptor.code, 'media.microphone');
    expect(descriptor.apiVersion, '1.1.0');
    expect(descriptor.methods.map((method) => method.name), ['toText']);
    expect(descriptor.methods.single.requiresUserActivation, isTrue);
    expect(descriptor.events.map((event) => event.name), [
      'textOnSoundLevelChange',
      'textOnResult',
    ]);
  });

  test('toText 传递语言和时限并转发声音级别与完整识别结果', () async {
    final engine = _FakeSpeechRecognitionEngine();
    final plugin = AudioCapabilityPlugin(speechEngine: engine);
    final instance = await plugin.create(const {});
    final events = <CapabilityInstanceEvent>[];
    final subscription = instance.events.listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(plugin.dispose);

    final result = await instance.invoke('toText', {
      'localeId': 'zh_CN',
      'listenFor': 30,
      'pauseFor': 3,
    });
    engine.emitSoundLevel(12.5);
    engine.emitResult(
      const AudioSpeechRecognitionResult(
        recognizedWords: '你好世界',
        finalResult: true,
        resultType: 'finalResult',
        confidence: 0.9,
        hasConfidenceRating: true,
        alternates: [
          AudioSpeechRecognitionAlternative(
            recognizedWords: '你好，世界',
            recognizedPhrases: ['你好，世界'],
            confidence: 0.8,
            hasConfidenceRating: true,
          ),
        ],
      ),
    );
    await pumpEventQueue();

    expect(result, {'started': true});
    expect(engine.initializeCount, 1);
    expect(engine.diagnosisCount, 0);
    expect(engine.localeId, 'zh_CN');
    expect(engine.listenFor, const Duration(seconds: 30));
    expect(engine.pauseFor, const Duration(seconds: 3));
    expect(events, hasLength(2));

    final soundEvent = events[0];
    expect(soundEvent.name, 'textOnSoundLevelChange');
    expect(soundEvent.data, {'level': 12.5});

    final resultEvent = events[1];
    expect(resultEvent.name, 'textOnResult');
    expect(resultEvent.data, {
      'recognizedWords': '你好世界',
      'finalResult': true,
      'resultType': 'finalResult',
      'confidence': 0.9,
      'hasConfidenceRating': true,
      'alternates': [
        {
          'recognizedWords': '你好，世界',
          'recognizedPhrases': ['你好，世界'],
          'confidence': 0.8,
          'hasConfidenceRating': true,
        },
      ],
    });

    await instance.dispose();
    expect(engine.cancelCount, 1);
  });

  test('toText 拒绝无效参数、并发识别和重复实例', () async {
    final engine = _FakeSpeechRecognitionEngine();
    final plugin = AudioCapabilityPlugin(speechEngine: engine);
    final instance = await plugin.create(const {});
    addTearDown(plugin.dispose);

    await expectLater(
      instance.invoke('toText', {
        'localeId': '',
        'listenFor': 30,
        'pauseFor': 3,
      }),
      throwsFormatException,
    );
    await expectLater(plugin.create(const {}), throwsStateError);

    await instance.invoke('toText', {
      'localeId': 'en_US',
      'listenFor': 10,
      'pauseFor': 2,
    });
    await expectLater(
      instance.invoke('toText', {
        'localeId': 'en_US',
        'listenFor': 10,
        'pauseFor': 2,
      }),
      throwsA(
        isA<CapabilityOperationException>().having(
          (error) => error.code,
          'code',
          'speech_recognizer_busy',
        ),
      ),
    );
  });

  test('完整创建先初始化引擎，失败后才用平台诊断细分原因', () async {
    final engine = _FakeSpeechRecognitionEngine(
      initializeResult: false,
      diagnosisResult: const AudioSpeechInitializationDiagnosis.unavailable(
        code: 'speech_recognizer_unavailable',
        message: '系统未安装或未启用语音识别服务',
      ),
    );
    final plugin = AudioCapabilityPlugin(speechEngine: engine);
    addTearDown(plugin.dispose);

    await expectLater(
      plugin.create(const {}),
      throwsA(
        isA<CapabilityOperationException>().having(
          (error) => error.code,
          'code',
          'speech_recognizer_unavailable',
        ),
      ),
    );

    expect(engine.initializeCount, 1);
    expect(engine.diagnosisCount, 1);
  });

  test('真实初始化失败但平台诊断可用时保留初始化失败原因', () async {
    final engine = _FakeSpeechRecognitionEngine(initializeResult: false);
    final plugin = AudioCapabilityPlugin(speechEngine: engine);
    addTearDown(plugin.dispose);

    await expectLater(
      plugin.create(const {}),
      throwsA(
        isA<CapabilityOperationException>().having(
          (error) => error.code,
          'code',
          'speech_engine_initialization_failed',
        ),
      ),
    );

    expect(engine.initializeCount, 1);
    expect(engine.diagnosisCount, 1);
  });
}

class _FakeSpeechRecognitionEngine implements AudioSpeechRecognitionEngine {
  _FakeSpeechRecognitionEngine({
    this.initializeResult = true,
    this.diagnosisResult = const AudioSpeechInitializationDiagnosis.available(),
  });

  final bool initializeResult;
  final AudioSpeechInitializationDiagnosis diagnosisResult;
  bool initialized = false;
  int initializeCount = 0;
  int diagnosisCount = 0;
  int cancelCount = 0;
  String? localeId;
  Duration? listenFor;
  Duration? pauseFor;
  void Function(double level)? _onSoundLevelChange;
  AudioSpeechResultCallback? _onResult;

  @override
  bool isListening = false;

  @override
  Future<AudioSpeechInitializationDiagnosis>
  diagnoseInitializationFailure() async {
    diagnosisCount += 1;
    return diagnosisResult;
  }

  @override
  Future<bool> initialize({
    required void Function(Object error) onError,
  }) async {
    initialized = initializeResult;
    initializeCount += 1;
    return initializeResult;
  }

  @override
  Future<void> listen({
    required String localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required void Function(double level) onSoundLevelChange,
    required AudioSpeechResultCallback onResult,
  }) async {
    if (!initialized) throw StateError('尚未初始化');
    this.localeId = localeId;
    this.listenFor = listenFor;
    this.pauseFor = pauseFor;
    _onSoundLevelChange = onSoundLevelChange;
    _onResult = onResult;
    isListening = true;
  }

  void emitSoundLevel(double level) => _onSoundLevelChange?.call(level);

  void emitResult(AudioSpeechRecognitionResult result) =>
      _onResult?.call(result);

  @override
  Future<void> stop() async {
    isListening = false;
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
    isListening = false;
  }
}
