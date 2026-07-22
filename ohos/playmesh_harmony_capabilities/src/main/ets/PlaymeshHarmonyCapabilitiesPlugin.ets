import {
  FlutterPlugin,
  FlutterPluginBinding
} from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import AbilityAware from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityAware';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import EventChannel, {
  EventSink,
  StreamHandler
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { BinaryMessenger } from '@ohos/flutter_ohos';
import sensor from '@ohos.sensor';
import vibrator from '@ohos.vibrator';
import window from '@ohos.window';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import playmeshCore from 'libplaymesh_core_napi.so';

const DEVICE_CHANNEL = 'playmesh/harmony_capabilities';
const GO_CORE_CHANNEL = 'playmesh/go_core_host';
const SENSOR_METHOD_CHANNEL = 'dev.fluttercommunity.plus/sensors/method';
const ACCELEROMETER_CHANNEL = 'dev.fluttercommunity.plus/sensors/accelerometer';
const GYROSCOPE_CHANNEL = 'dev.fluttercommunity.plus/sensors/gyroscope';

/**
 * Adapter seam for a Harmony-native Playmesh Core SDK.
 *
 * The application can inject an implementation when its signed native SDK is
 * available. Keeping this contract in the HAR avoids coupling the Flutter app
 * to a particular SDK packaging or ABI.
 */
export interface PlaymeshHarmonyCoreAdapter {
  start(address: string): Promise<string>;
  stop(): Promise<void>;
}

/** Production adapter backed by the Playmesh Core library packaged in the HAR. */
export class NativePlaymeshHarmonyCoreAdapter implements PlaymeshHarmonyCoreAdapter {
  async start(address: string): Promise<string> {
    const requestedAddress = address.length > 0 ? address : '0.0.0.0:0';
    const boundAddress: string = await playmeshCore.start(requestedAddress);
    if (boundAddress.length === 0 || boundAddress.endsWith(':0')) {
      throw new Error(`Playmesh Core returned an invalid address: ${boundAddress}`);
    }
    return boundAddress;
  }

  async stop(): Promise<void> {
    await playmeshCore.stop();
  }
}

class SensorStreamHandler implements StreamHandler {
  private readonly sensorId: sensor.SensorId;
  private eventSink?: EventSink;
  private intervalNs: number = 200000000;

  constructor(sensorId: sensor.SensorId) {
    this.sensorId = sensorId;
  }

  setSamplingPeriod(microseconds: number): void {
    const requestedNs = Math.max(10000000, microseconds * 1000);
    if (requestedNs === this.intervalNs) {
      return;
    }
    this.intervalNs = requestedNs;
    if (this.eventSink) {
      this.stop();
      this.start();
    }
  }

  onListen(_args: ESObject, events: EventSink): void {
    this.eventSink = events;
    this.start();
  }

  onCancel(_args: ESObject): void {
    this.stop();
    this.eventSink = undefined;
  }

  dispose(): void {
    this.stop();
    this.eventSink = undefined;
  }

  private start(): void {
    if (this.sensorId === sensor.SensorId.ACCELEROMETER) {
      sensor.on(
        sensor.SensorId.ACCELEROMETER,
        (data: sensor.AccelerometerResponse) => this.emit(data.x, data.y, data.z),
        { interval: this.intervalNs }
      );
      return;
    }
    sensor.on(
      sensor.SensorId.GYROSCOPE,
      (data: sensor.GyroscopeResponse) => this.emit(data.x, data.y, data.z),
      { interval: this.intervalNs }
    );
  }

  private stop(): void {
    if (this.sensorId === sensor.SensorId.ACCELEROMETER) {
      sensor.off(sensor.SensorId.ACCELEROMETER);
      return;
    }
    sensor.off(sensor.SensorId.GYROSCOPE);
  }

  private emit(x: number, y: number, z: number): void {
    // StandardMessageCodec must encode these values as doubles because the
    // sensors_plus Dart implementation casts the complete list to double.
    const timestampMicros = Date.now() * 1000 + 0.000001;
    this.eventSink?.success([
      Number.isInteger(x) ? x + 0.000001 : x,
      Number.isInteger(y) ? y + 0.000001 : y,
      Number.isInteger(z) ? z + 0.000001 : z,
      timestampMicros
    ]);
  }
}

export default class PlaymeshHarmonyCapabilitiesPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private readonly coreAdapter: PlaymeshHarmonyCoreAdapter;
  private deviceChannel?: MethodChannel;
  private sensorMethodChannel?: MethodChannel;
  private coreChannel?: MethodChannel;
  private accelerometerChannel?: EventChannel;
  private gyroscopeChannel?: EventChannel;
  private context?: common.UIAbilityContext;
  private readonly accelerometer = new SensorStreamHandler(sensor.SensorId.ACCELEROMETER);
  private readonly gyroscope = new SensorStreamHandler(sensor.SensorId.GYROSCOPE);

  constructor(coreAdapter: PlaymeshHarmonyCoreAdapter) {
    this.coreAdapter = coreAdapter;
  }

  getUniqueClassName(): string {
    return 'PlaymeshHarmonyCapabilitiesPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger: BinaryMessenger = binding.getBinaryMessenger();
    this.deviceChannel = new MethodChannel(messenger, DEVICE_CHANNEL);
    this.deviceChannel.setMethodCallHandler(this);
    this.sensorMethodChannel = new MethodChannel(messenger, SENSOR_METHOD_CHANNEL);
    this.sensorMethodChannel.setMethodCallHandler(this);
    this.coreChannel = new MethodChannel(messenger, GO_CORE_CHANNEL);
    this.coreChannel.setMethodCallHandler(this);
    this.accelerometerChannel = new EventChannel(messenger, ACCELEROMETER_CHANNEL);
    this.accelerometerChannel.setStreamHandler(this.accelerometer);
    this.gyroscopeChannel = new EventChannel(messenger, GYROSCOPE_CHANNEL);
    this.gyroscopeChannel.setStreamHandler(this.gyroscope);
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = undefined;
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.deviceChannel?.setMethodCallHandler(null);
    this.sensorMethodChannel?.setMethodCallHandler(null);
    this.coreChannel?.setMethodCallHandler(null);
    this.accelerometerChannel?.setStreamHandler(null);
    this.gyroscopeChannel?.setStreamHandler(null);
    this.accelerometer.dispose();
    this.gyroscope.dispose();
    this.context = undefined;
    this.accelerometerChannel = undefined;
    this.gyroscopeChannel = undefined;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getCapabilities':
        result.success([
          'fullscreen',
          'haptics',
          'accelerometer',
          'gyroscope',
          'share-files',
          'go-core-host'
        ]);
        return;
      case 'haptic':
        this.haptic(call.argument('style') as string, result);
        return;
      case 'setFullscreen':
        this.setFullscreen(call.argument('enabled') as boolean, result);
        return;
      case 'shareFiles':
        this.shareFiles(
          call.argument('paths') as string[],
          call.argument('mimeTypes') as string[],
          result
        );
        return;
      case 'setAccelerationSamplingPeriod':
        this.accelerometer.setSamplingPeriod(call.args as number);
        result.success(null);
        return;
      case 'setGyroscopeSamplingPeriod':
        this.gyroscope.setSamplingPeriod(call.args as number);
        result.success(null);
        return;
      case 'start':
        this.startCore(call.argument('address') as string, result);
        return;
      case 'stop':
        this.stopCore(result);
        return;
      default:
        result.notImplemented();
    }
  }

  private startCore(address: string, result: MethodResult): void {
    const adapter = this.coreAdapter;
    adapter.start(address)
      .then((boundAddress: string) => result.success(boundAddress))
      .catch((error: Error) => {
        result.error('harmony_core_start_failed', error.message, null);
      });
  }

  private stopCore(result: MethodResult): void {
    const adapter = this.coreAdapter;
    adapter.stop()
      .then(() => result.success(null))
      .catch((error: Error) => {
        result.error('harmony_core_stop_failed', error.message, null);
      });
  }

  private haptic(style: string, result: MethodResult): void {
    const durations = new Map<string, number>([
      ['selection', 15],
      ['light', 25],
      ['medium', 40],
      ['heavy', 60],
      ['vibrate', 100]
    ]);
    const duration = durations.get(style);
    if (!duration) {
      result.error('invalid_haptic_style', `Unsupported haptic style: ${style}`, null);
      return;
    }
    vibrator.startVibration(
      { type: 'time', duration: duration },
      { id: 0, usage: 'touch' }
    ).then(() => result.success(null)).catch((error: BusinessError) => {
      result.error(String(error.code), error.message, null);
    });
  }

  private setFullscreen(enabled: boolean, result: MethodResult): void {
    const context = this.context;
    if (!context) {
      result.error('missing_context', 'Harmony application context is unavailable', null);
      return;
    }
    window.getLastWindow(context)
      .then((mainWindow: window.Window) => mainWindow.setWindowLayoutFullScreen(enabled))
      .then(() => result.success(null))
      .catch((error: BusinessError) => {
        result.error(String(error.code), error.message, null);
      });
  }

  private shareFiles(paths: string[], mimeTypes: string[], result: MethodResult): void {
    const context = this.context;
    if (!context) {
      result.error('missing_context', 'Harmony application context is unavailable', null);
      return;
    }
    if (paths.length === 0) {
      result.error('missing_share_file', 'At least one file is required', null);
      return;
    }
    const uri = fileUri.getUriFromPath(paths[0]);
    const mimeType = mimeTypes.length > 0 && mimeTypes[0].length > 0
      ? mimeTypes[0]
      : 'application/octet-stream';
    const want: Want = {
      action: 'ohos.want.action.sendData',
      uri: uri,
      type: mimeType,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    context.startAbility(want)
      .then(() => result.success(null))
      .catch((error: BusinessError) => {
        result.error(String(error.code), error.message, null);
      });
  }
}
