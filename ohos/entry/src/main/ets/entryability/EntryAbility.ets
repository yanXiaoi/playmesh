import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import PlaymeshHarmonyCapabilitiesPlugin, {
  NativePlaymeshHarmonyCoreAdapter
} from '@playmesh/harmony_capabilities';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    this.addPlugin(new PlaymeshHarmonyCapabilitiesPlugin(
      new NativePlaymeshHarmonyCoreAdapter()
    ));
  }
}
