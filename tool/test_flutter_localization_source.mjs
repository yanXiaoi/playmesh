import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const workspaceRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

function dartFiles(root) {
  const result = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      result.push(...dartFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".dart")) {
      result.push(entryPath);
    }
  }
  return result;
}

function skipString(source, start) {
  const quote = source[start];
  const triple = source.slice(start, start + 3) === quote.repeat(3);
  const raw =
    start > 0 &&
    /[rR]/.test(source[start - 1]) &&
    (start < 2 || !/[A-Za-z0-9_]/.test(source[start - 2]));
  const delimiterLength = triple ? 3 : 1;
  for (let index = start + delimiterLength; index < source.length;) {
    if (source.slice(index, index + delimiterLength) === quote.repeat(delimiterLength)) {
      return index + delimiterLength;
    }
    if (!raw && source[index] === "\\") {
      index += 2;
    } else {
      index += 1;
    }
  }
  return source.length;
}

function skipBlockComment(source, start) {
  let depth = 1;
  for (let index = start + 2; index < source.length - 1; index += 1) {
    if (source.startsWith("/*", index)) {
      depth += 1;
      index += 1;
    } else if (source.startsWith("*/", index)) {
      depth -= 1;
      index += 1;
      if (depth === 0) return index + 1;
    }
  }
  return source.length;
}

function codeMask(source) {
  const chars = source.split("");
  for (let index = 0; index < source.length;) {
    if (source.startsWith("//", index)) {
      const end = source.indexOf("\n", index + 2);
      const limit = end < 0 ? source.length : end;
      for (let cursor = index; cursor < limit; cursor += 1) chars[cursor] = " ";
      index = limit;
    } else if (source.startsWith("/*", index)) {
      const end = skipBlockComment(source, index);
      for (let cursor = index; cursor < end; cursor += 1) {
        if (chars[cursor] !== "\n") chars[cursor] = " ";
      }
      index = end;
    } else if (source[index] === "'" || source[index] === '"') {
      const start =
        index > 0 &&
        /[rR]/.test(source[index - 1]) &&
        (index < 2 || !/[A-Za-z0-9_]/.test(source[index - 2]))
          ? index - 1
          : index;
      const end = skipString(source, index);
      for (let cursor = start; cursor < end; cursor += 1) {
        if (chars[cursor] !== "\n") chars[cursor] = " ";
      }
      index = end;
    } else {
      index += 1;
    }
  }
  return chars.join("");
}

function callArguments(source, openParenthesis) {
  const stack = [")"];
  const commas = [];
  for (let index = openParenthesis + 1; index < source.length;) {
    if (source.startsWith("//", index)) {
      const end = source.indexOf("\n", index + 2);
      index = end < 0 ? source.length : end;
      continue;
    }
    if (source.startsWith("/*", index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    const character = source[index];
    if (character === "'" || character === '"') {
      index = skipString(source, index);
      continue;
    }
    if (character === "(" || character === "[" || character === "{") {
      stack.push(character === "(" ? ")" : character === "[" ? "]" : "}");
      index += 1;
      continue;
    }
    if (character === stack.at(-1)) {
      stack.pop();
      if (stack.length === 0) {
        const boundaries = [openParenthesis, ...commas, index];
        return {
          closeParenthesis: index,
          arguments: boundaries.slice(0, -1).map((boundary, argumentIndex) => ({
            start: boundary + 1,
            end: boundaries[argumentIndex + 1],
          })),
        };
      }
      index += 1;
      continue;
    }
    if (character === "," && stack.length === 1) commas.push(index);
    index += 1;
  }
  throw new Error(`Unterminated .tr call at offset ${openParenthesis}`);
}

export function findTrCalls(source, filePath = "<source>") {
  const mask = codeMask(source);
  const pattern = /(?:\?\.|\.)tr\s*\(/g;
  const calls = [];
  for (const match of mask.matchAll(pattern)) {
    const openParenthesis = mask.indexOf("(", match.index);
    const parsed = callArguments(source, openParenthesis);
    const argumentsWithSource = parsed.arguments.map((argument) => ({
      ...argument,
      source: source.slice(argument.start, argument.end),
    }));
    calls.push({
      filePath,
      start: match.index,
      openParenthesis,
      closeParenthesis: parsed.closeParenthesis,
      line: source.slice(0, match.index).split("\n").length,
      arguments: argumentsWithSource,
    });
  }
  return calls;
}

function staticString(argument) {
  const value = argument.trim();
  const match = value.match(/^[rR]?(['"])([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\1$/);
  return match?.[2] ?? null;
}

function relative(filePath) {
  return path.relative(workspaceRoot, filePath).replaceAll("\\", "/");
}

function main() {
  const parserProbe = findTrCalls(
    "final ignored = '😀.tr(';\n" +
      "context.tr('probe.outer', arguments: {'value': context.tr('probe.inner')});",
  );
  assert.deepEqual(
    parserProbe.map((call) => staticString(call.arguments[0].source)),
    ["probe.outer", "probe.inner"],
    "The Dart call scanner must preserve UTF-16 offsets and nested tr calls",
  );

  const libSources = dartFiles(path.join(workspaceRoot, "lib"));
  const testSources = dartFiles(path.join(workspaceRoot, "test"));
  const libCalls = libSources.flatMap((filePath) =>
    findTrCalls(fs.readFileSync(filePath, "utf8"), filePath),
  );
  const calls = [...libCalls, ...testSources.flatMap((filePath) =>
    findTrCalls(fs.readFileSync(filePath, "utf8"), filePath),
  )];

  const fallbackCalls = calls.filter((call) =>
    call.arguments.some((argument) => /^\s*fallback\s*:/.test(argument.source)),
  );
  assert.deepEqual(
    fallbackCalls.map((call) => `${relative(call.filePath)}:${call.line}`),
    [],
    "BuildContext.tr calls must not define call-site fallback text",
  );

  const staticCalls = libCalls
    .map((call) => ({
      call,
      key: call.arguments.length > 0 ? staticString(call.arguments[0].source) : null,
    }))
    .filter((entry) => entry.key !== null);
  const staticKeys = new Set(staticCalls.map((entry) => entry.key));
  const dynamicArguments = new Set(
    libCalls
      .map((call) => call.arguments[0]?.source.trim() ?? "")
      .filter((argument) => staticString(argument) === null)
      .map((argument) => argument.replaceAll(/\s+/g, " ")),
  );
  const joinErrorKeys = [
    "join.invalid_invite",
    "join.game_mismatch",
    "join.self_invitation",
    "join.discovery_not_found",
    "join.nearby_failed",
    "join.game_context_unavailable",
    "join.cancelled",
  ];
  const dynamicKeyFamilies = new Map([
    ["'release.highlight_${index + 1}'", []],
    [
      "'settings.theme_${preferences.theme.wireName}'",
      ["settings.theme_system", "settings.theme_light", "settings.theme_dark"],
    ],
    [
      "'settings.update_platform_$platform'",
      [
        "settings.update_platform_android",
        "settings.update_platform_ios",
        "settings.update_platform_linux",
        "settings.update_platform_macos",
        "settings.update_platform_web",
        "settings.update_platform_windows",
      ],
    ],
    [
      "_avatarBytes == null ? 'profile.choose_avatar' : 'profile.choose_avatar_again'",
      ["profile.choose_avatar", "profile.choose_avatar_again"],
    ],
    ["_joinErrorKey!", joinErrorKeys],
    [
      "enabled ? 'game.fullscreen_enter_failed' : 'game.fullscreen_exit_failed'",
      ["game.fullscreen_enter_failed", "game.fullscreen_exit_failed"],
    ],
    ["gameJoinErrorLocalizationKey(error)", joinErrorKeys],
    [
      "loading ? 'common.loading' : section.error == null ? 'common.load_more' : 'common.retry'",
      ["common.loading", "common.load_more", "common.retry"],
    ],
    [
      "messageKey",
      [
        "join.nearby_empty",
        "join.nearby_scanning",
        "join.nearby_permission_denied",
        "join.nearby_unsupported",
        "join.nearby_failed",
      ],
    ],
    [
      "opened ? 'settings.update_browser_opened' : 'settings.update_browser_failed'",
      ["settings.update_browser_opened", "settings.update_browser_failed"],
    ],
    [
      "selected == null ? 'creator.gdevelop_choose_zip' : 'creator.gdevelop_change_zip'",
      ["creator.gdevelop_choose_zip", "creator.gdevelop_change_zip"],
    ],
    [
      "state.targetEnabled == false ? 'creator.stopping' : 'creator.starting'",
      ["creator.stopping", "creator.starting"],
    ],
  ]);
  assert.deepEqual(
    [...dynamicArguments].sort(),
    [...dynamicKeyFamilies.keys()].sort(),
    "Every dynamic BuildContext.tr key family must have explicit coverage",
  );
  const releaseNotesSource = fs.readFileSync(
    path.join(
      workspaceRoot,
      "lib",
      "core",
      "release",
      "playmesh_release_notes.dart",
    ),
    "utf8",
  );
  const highlightCount = Number(
    releaseNotesSource.match(/playmeshReleaseHighlightCount\s*=\s*(\d+)/)?.[1],
  );
  assert.ok(Number.isInteger(highlightCount) && highlightCount > 0);
  dynamicKeyFamilies.set(
    "'release.highlight_${index + 1}'",
    Array.from(
      { length: highlightCount },
      (_, index) => `release.highlight_${index + 1}`,
    ),
  );
  const requiredKeys = new Set([
    ...staticKeys,
    ...[...dynamicKeyFamilies.values()].flat(),
  ]);

  const localizationRoot = path.join(workspaceRoot, "assets", "playmesh-localization");
  const manifest = JSON.parse(
    fs.readFileSync(path.join(localizationRoot, "manifest.json"), "utf8"),
  );
  const enabledLocales = manifest.locales.filter((locale) => locale.enabled);
  assert.ok(enabledLocales.length > 0, "Localization manifest has no enabled locales");

  const appMessagesByLocale = new Map();
  for (const locale of enabledLocales) {
    const messages = JSON.parse(
      fs.readFileSync(path.join(localizationRoot, locale.bundles.app), "utf8"),
    );
    appMessagesByLocale.set(locale.id, messages);
    const missing = [...requiredKeys].filter((key) => !(key in messages)).sort();
    assert.deepEqual(
      missing,
      [],
      `${locale.id} app.json is missing static BuildContext.tr keys`,
    );
  }

  const referenceLocale = enabledLocales[0].id;
  const referenceMessages = appMessagesByLocale.get(referenceLocale);
  const referenceKeys = Object.keys(referenceMessages).sort();
  const placeholders = value =>
    [...value.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)]
      .map(match => match[1])
      .sort();
  for (const locale of enabledLocales.slice(1)) {
    const messages = appMessagesByLocale.get(locale.id);
    assert.deepEqual(
      Object.keys(messages).sort(),
      referenceKeys,
      `${locale.id} app.json keys must exactly match ${referenceLocale}`,
    );
    for (const key of referenceKeys) {
      assert.deepEqual(
        placeholders(messages[key]),
        placeholders(referenceMessages[key]),
        `${locale.id} app.json placeholders for ${key} must match ${referenceLocale}`,
      );
    }
  }

  const localizationSource = fs.readFileSync(
    path.join(workspaceRoot, "lib", "core", "localization", "playmesh_localization.dart"),
    "utf8",
  );
  assert.match(
    localizationSource,
    /String tr\(\s*String key,\s*\{\s*Map<String, Object\?> arguments = const \{\},?\s*\}\)/,
  );
  assert.match(
    localizationSource,
    /PlaymeshLocalizations\.of\(this\)\.text\(key, arguments: arguments\)/,
  );
  assert.match(
    localizationSource,
    /if \(value == null\) \{\s*throw FlutterError\(/,
  );
  assert.match(
    localizationSource,
    /if \(template == null\) \{\s*throw FlutterError\('Missing localized message:/,
  );

  const appSource = fs.readFileSync(
    path.join(workspaceRoot, "lib", "app.dart"),
    "utf8",
  );
  assert.match(
    appSource,
    /playmesh_localization_bootstrap_failed\\n\$\{snapshot\.error\}/,
  );
  assert.doesNotMatch(
    appSource,
    /Playmesh UI configuration failed|Could not open file/,
  );

  const remoteGameSource = fs.readFileSync(
    path.join(workspaceRoot, "lib", "features", "game", "remote_game_page.dart"),
    "utf8",
  );
  assert.match(remoteGameSource, /context\.tr\('game\.remote_open_failed'\)/);
  assert.doesNotMatch(
    remoteGameSource,
    /game\.remote_open_failed[\s\S]{0,160}arguments\s*:\s*\{\s*['"]error['"]\s*:/,
    "Remote game failures must not expose raw platform or WebView error text",
  );
  for (const messages of appMessagesByLocale.values()) {
    assert.doesNotMatch(
      messages["game.remote_open_failed"],
      /\{error\}/,
      "The public remote-game failure message must remain sanitized",
    );
  }

  console.log(
    `Flutter localization source contract passed: ${libCalls.length} App tr calls, ` +
      `${staticKeys.size} static keys, ${enabledLocales.length} enabled locales.`,
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  main();
}
