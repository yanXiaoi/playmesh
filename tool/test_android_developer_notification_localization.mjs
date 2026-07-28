import assert from "node:assert/strict";
import fs from "node:fs";

const read = (path) =>
  fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const manifest = JSON.parse(read("assets/playmesh-localization/manifest.json"));
const backgroundHostSource = read(
  "lib/core/developer/developer_background_host.dart",
);
const runtimeSource = read("lib/core/services/go_core_runtime.dart");
const appSource = read("lib/app.dart");
const activitySource = read(
  "android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java",
);
const serviceSource = read(
  "android/app/src/main/java/top/zfjmm/playmesh/DeveloperForegroundService.java",
);

const requiredKeys = [
  "platform.android.developer_service.channel_name",
  "platform.android.developer_service.channel_description",
  "platform.android.developer_service.title",
  "platform.android.developer_service.listening",
  "platform.android.developer_service.running",
];

for (const locale of manifest.locales) {
  const appMessages = JSON.parse(
    read(`assets/playmesh-localization/${locale.bundles.app}`),
  );
  for (const key of requiredKeys) {
    assert.equal(
      typeof appMessages[key],
      "string",
      `${locale.id} is missing ${key}`,
    );
    assert.ok(appMessages[key].length > 0, `${locale.id} has an empty ${key}`);
  }
  assert.match(
    appMessages["platform.android.developer_service.listening"],
    /\{port\}/,
    `${locale.id} listening notification must preserve the port placeholder`,
  );
}

for (const key of requiredKeys) {
  assert.ok(backgroundHostSource.includes(`'${key}'`));
  assert.ok(serviceSource.includes(`"${key}"`));
}
assert.match(backgroundHostSource, /'port': port/);
assert.match(backgroundHostSource, /'localeId': localeId/);
assert.match(backgroundHostSource, /'messages': messages/);
assert.match(runtimeSource, /refreshDeveloperBackgroundNotification/);
assert.match(appSource, /resolvedMessages\([\s\S]*PlaymeshLocalizationBundle\.app/);
assert.match(
  appSource,
  /setDeveloperBackgroundNotificationLocalizationProvider/,
);
assert.match(appSource, /didChangeLocales/);
assert.match(activitySource, /case "updateNotification":/);
assert.match(serviceSource, /listening\.replace\("\{port\}", Integer\.toString\(port\)\)/);

for (const removedLiteral of [
  "Playmesh 开发者工作区",
  "保持本机开发者工作区在后台可访问",
  "Playmesh 开发者模式",
  "端口 ",
  "正在监听；点击返回 App",
  "开发者工作区正在后台运行；点击返回 App",
]) {
  assert.equal(
    serviceSource.includes(removedLiteral),
    false,
    `Android service still hardcodes visible copy: ${removedLiteral}`,
  );
}

console.log("Android developer notification localization contract passed.");
