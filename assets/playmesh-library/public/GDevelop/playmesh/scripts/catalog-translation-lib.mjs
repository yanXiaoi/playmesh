import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

const CACHE_SCHEMA_VERSION = 1;
const SIDECAR_SCHEMA_VERSION = 1;
const SOURCE_LANGUAGE = 'en';
const DEFAULT_TIMEOUT_MS = 15000;
const MAX_BATCH_ITEMS = 50;
const MAX_BATCH_CHARACTERS = 24000;

const sha256 = value =>
  createHash('sha256').update(String(value), 'utf8').digest('hex');

const canonicalCacheKey = ({
  sourceCommit,
  artifactId,
  field,
  sourceText,
  targetLocale,
  provider,
  providerVersion,
}) =>
  sha256(
    JSON.stringify({
      schemaVersion: CACHE_SCHEMA_VERSION,
      sourceCommit,
      artifactId,
      field,
      sourceTextSha256: sha256(sourceText),
      targetLocale,
      provider,
      providerVersion,
    })
  );

export const normalizeCatalogLocale = value => {
  const normalized = String(value || '').trim().replace(/_/g, '-').toLowerCase();
  if (['zh', 'zh-cn', 'zh-hans', 'zh-sg'].includes(normalized)) return 'zh-CN';
  return '';
};

const addUnit = (units, unit) => {
  const sourceText = String(unit.sourceText || '').trim();
  if (!sourceText || !/[A-Za-z]/.test(sourceText)) return;
  units.push({ ...unit, sourceText });
};

export const collectCatalogTranslationUnits = ({
  extensionsIndex,
  examplesIndex,
}) => {
  const units = [];
  const extensionCommit = extensionsIndex.source.commit;
  const exampleCommit = examplesIndex.source.commit;
  for (const header of extensionsIndex.headers || []) {
    const artifactId = `extension:${header.name}`;
    for (const field of ['fullName', 'shortDescription', 'description']) {
      addUnit(units, {
        section: 'extensions',
        entryId: header.name,
        artifactId,
        field,
        sourceCommit: extensionCommit,
        sourceText: header[field],
      });
    }
  }
  for (const header of extensionsIndex.behavior?.headers || []) {
    const entryId = `${header.extensionName}:${header.name}`;
    for (const field of ['fullName', 'description']) {
      addUnit(units, {
        section: 'behaviors',
        entryId,
        artifactId: `behavior:${entryId}`,
        field,
        sourceCommit: extensionCommit,
        sourceText: header[field],
      });
    }
  }
  for (const header of examplesIndex.headers || []) {
    const artifactId = `example:${header.id}`;
    for (const field of ['name', 'shortDescription', 'description']) {
      addUnit(units, {
        section: 'examples',
        entryId: header.id,
        artifactId,
        field,
        sourceCommit: exampleCommit,
        sourceText: header[field],
      });
    }
  }
  return units;
};

const emptyCache = () => ({ schemaVersion: CACHE_SCHEMA_VERSION, entries: {} });

const readCache = async (cachePath, warn) => {
  try {
    const value = JSON.parse(await readFile(cachePath, 'utf8'));
    if (
      value?.schemaVersion !== CACHE_SCHEMA_VERSION ||
      !value.entries ||
      typeof value.entries !== 'object' ||
      Array.isArray(value.entries)
    ) {
      throw new Error('schema mismatch');
    }
    return value;
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      warn(`忽略不可用的翻译缓存：${error.message || String(error)}`);
    }
    return emptyCache();
  }
};

const writeCache = async (cachePath, cache, warn) => {
  const temporaryPath = `${cachePath}.tmp-${process.pid}-${randomUUID()}`;
  try {
    await mkdir(path.dirname(cachePath), { recursive: true });
    await writeFile(temporaryPath, `${JSON.stringify(cache, null, 2)}\n`, 'utf8');
    await rename(temporaryPath, cachePath);
  } catch (error) {
    warn(`翻译结果已生成，但缓存写入失败：${error.message || String(error)}`);
  }
};

const decodeHtmlEntities = value =>
  String(value || '').replace(
    /&(#x?[0-9a-f]+|quot|apos|#39|amp|lt|gt);/gi,
    (match, entity) => {
      const normalized = entity.toLowerCase();
      if (normalized === 'quot') return '"';
      if (normalized === 'apos' || normalized === '#39') return "'";
      if (normalized === 'amp') return '&';
      if (normalized === 'lt') return '<';
      if (normalized === 'gt') return '>';
      const radix = normalized.startsWith('#x') ? 16 : 10;
      const digits = normalized.replace(/^#x?/, '');
      const codePoint = Number.parseInt(digits, radix);
      return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : match;
    }
  );

export const requestTranslationJson = async ({
  url,
  headers,
  body,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) => {
  if (typeof globalThis.fetch !== 'function') {
    throw new Error('当前 Node.js 不支持 fetch，无法请求官方翻译接口。');
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await globalThis.fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
};

const assertOfficialEndpoint = (value, allowedHosts, label) => {
  const url = new URL(value);
  if (
    url.protocol !== 'https:' ||
    !allowedHosts.some(host =>
      host.startsWith('.') ? url.hostname.endsWith(host) : url.hostname === host
    )
  ) {
    throw new Error(`${label} 必须使用官方 HTTPS 接口。`);
  }
  return url;
};

export const createOfficialTranslationProviders = ({
  environment = process.env,
  requestJson = requestTranslationJson,
  timeoutMs = DEFAULT_TIMEOUT_MS,
} = {}) => {
  const microsoftKey =
    environment.PLAYMESH_MICROSOFT_TRANSLATOR_KEY ||
    environment.AZURE_TRANSLATOR_KEY ||
    '';
  const microsoftRegion =
    environment.PLAYMESH_MICROSOFT_TRANSLATOR_REGION ||
    environment.AZURE_TRANSLATOR_REGION ||
    '';
  const microsoftEndpoint =
    environment.PLAYMESH_MICROSOFT_TRANSLATOR_ENDPOINT ||
    'https://api.cognitive.microsofttranslator.com/translate';
  const googleKey =
    environment.PLAYMESH_GOOGLE_TRANSLATE_API_KEY ||
    environment.GOOGLE_TRANSLATE_API_KEY ||
    '';
  const googleEndpoint =
    environment.PLAYMESH_GOOGLE_TRANSLATE_ENDPOINT ||
    'https://translation.googleapis.com/language/translate/v2';

  return [
    {
      id: 'microsoft',
      version: 'text-translation-v3',
      available: !!microsoftKey,
      translateBatch: async (texts, targetLocale) => {
        const url = assertOfficialEndpoint(
          microsoftEndpoint,
          ['api.cognitive.microsofttranslator.com', '.cognitiveservices.azure.com'],
          'Microsoft Translator endpoint'
        );
        url.searchParams.set('api-version', '3.0');
        url.searchParams.set('from', SOURCE_LANGUAGE);
        url.searchParams.set('to', targetLocale === 'zh-CN' ? 'zh-Hans' : targetLocale);
        const headers = {
          'Content-Type': 'application/json; charset=UTF-8',
          'Ocp-Apim-Subscription-Key': microsoftKey,
          'X-ClientTraceId': randomUUID(),
        };
        if (microsoftRegion) {
          headers['Ocp-Apim-Subscription-Region'] = microsoftRegion;
        }
        const value = await requestJson({
          url: url.href,
          headers,
          body: texts.map(Text => ({ Text })),
          timeoutMs,
        });
        if (!Array.isArray(value) || value.length !== texts.length) {
          throw new Error('Microsoft Translator 返回数量不匹配。');
        }
        return value.map(item => String(item?.translations?.[0]?.text || '').trim());
      },
    },
    {
      id: 'google',
      version: 'cloud-translation-basic-v2',
      available: !!googleKey,
      translateBatch: async (texts, targetLocale) => {
        const url = assertOfficialEndpoint(
          googleEndpoint,
          ['translation.googleapis.com'],
          'Google Cloud Translation endpoint'
        );
        url.searchParams.set('key', googleKey);
        const value = await requestJson({
          url: url.href,
          headers: { 'Content-Type': 'application/json; charset=UTF-8' },
          body: {
            q: texts,
            source: SOURCE_LANGUAGE,
            target: targetLocale,
            format: 'text',
          },
          timeoutMs,
        });
        const translations = value?.data?.translations;
        if (!Array.isArray(translations) || translations.length !== texts.length) {
          throw new Error('Google Cloud Translation 返回数量不匹配。');
        }
        return translations.map(item =>
          decodeHtmlEntities(item?.translatedText).trim()
        );
      },
    },
  ];
};

const makeBatches = units => {
  const batches = [];
  let current = [];
  let characters = 0;
  for (const unit of units) {
    const nextCharacters = unit.sourceText.length;
    if (
      current.length &&
      (current.length >= MAX_BATCH_ITEMS ||
        characters + nextCharacters > MAX_BATCH_CHARACTERS)
    ) {
      batches.push(current);
      current = [];
      characters = 0;
    }
    current.push(unit);
    characters += nextCharacters;
  }
  if (current.length) batches.push(current);
  return batches;
};

const providerOrder = (providers, mode) => {
  if (mode === 'none') return [];
  if (mode === 'microsoft' || mode === 'google') {
    return providers.filter(provider => provider.id === mode);
  }
  if (mode !== 'auto') {
    throw new Error('--translation-provider 只接受 auto、microsoft、google 或 none。');
  }
  return providers;
};

const applyTranslation = (entries, unit, translation) => {
  if (!entries[unit.section][unit.entryId]) {
    entries[unit.section][unit.entryId] = {};
  }
  entries[unit.section][unit.entryId][unit.field] = translation;
};

export const generateCatalogTranslationSidecar = async ({
  extensionsIndex,
  examplesIndex,
  catalogRevision,
  targetLocale,
  cachePath,
  providerMode = 'auto',
  environment = process.env,
  requestJson = requestTranslationJson,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  warn = message => process.stderr.write(`[catalog-translation] ${message}\n`),
}) => {
  const locale = normalizeCatalogLocale(targetLocale);
  if (!locale) throw new Error(`暂不支持目录翻译语言：${targetLocale}`);
  const units = collectCatalogTranslationUnits({ extensionsIndex, examplesIndex });
  const cache = await readCache(cachePath, warn);
  const providers = providerOrder(
    createOfficialTranslationProviders({ environment, requestJson, timeoutMs }),
    providerMode
  );
  const entries = { extensions: {}, behaviors: {}, examples: {} };
  const usedProviders = new Set();
  const unresolved = [];
  let cachedFields = 0;

  for (const unit of units) {
    let cached = null;
    for (const provider of providers.length
      ? providers
      : createOfficialTranslationProviders({
          environment: {},
          requestJson,
          timeoutMs,
        })) {
      const key = canonicalCacheKey({
        ...unit,
        targetLocale: locale,
        provider: provider.id,
        providerVersion: provider.version,
      });
      const candidate = cache.entries[key];
      if (
        candidate &&
        candidate.sourceTextSha256 === sha256(unit.sourceText) &&
        typeof candidate.translation === 'string' &&
        candidate.translation.trim()
      ) {
        cached = candidate;
        break;
      }
    }
    if (cached) {
      applyTranslation(entries, unit, cached.translation);
      usedProviders.add(cached.provider);
      cachedFields += 1;
    } else {
      unresolved.push(unit);
    }
  }

  let pending = unresolved;
  for (const provider of providers) {
    if (!provider.available || !pending.length) continue;
    const stillPending = [];
    for (const batch of makeBatches(pending)) {
      try {
        const translations = await provider.translateBatch(
          batch.map(unit => unit.sourceText),
          locale
        );
        if (translations.length !== batch.length) {
          throw new Error('翻译数量不匹配。');
        }
        batch.forEach((unit, index) => {
          const translation = String(translations[index] || '').trim();
          if (!translation) {
            stillPending.push(unit);
            return;
          }
          applyTranslation(entries, unit, translation);
          const key = canonicalCacheKey({
            ...unit,
            targetLocale: locale,
            provider: provider.id,
            providerVersion: provider.version,
          });
          cache.entries[key] = {
            sourceCommit: unit.sourceCommit,
            artifactId: unit.artifactId,
            field: unit.field,
            sourceTextSha256: sha256(unit.sourceText),
            targetLocale: locale,
            provider: provider.id,
            providerVersion: provider.version,
            translation,
            updatedAt: new Date().toISOString(),
          };
          usedProviders.add(provider.id);
        });
        await writeCache(cachePath, cache, warn);
      } catch (error) {
        warn(
          `${provider.id} 官方翻译接口本批次不可用，继续使用缓存/英文：${
            error.message || String(error)
          }`
        );
        stillPending.push(...batch);
      }
    }
    pending = stillPending;
  }

  if (!providers.some(provider => provider.available) && unresolved.length) {
    warn('未配置官方翻译凭据；已使用现有缓存，未命中的字段保持英文。');
  }

  const translatedFields = units.length - pending.length;
  return {
    sidecar: {
      schemaVersion: SIDECAR_SCHEMA_VERSION,
      catalogRevision,
      locale,
      sourceLanguage: SOURCE_LANGUAGE,
      exactSources: {
        extensionsCommit: extensionsIndex.source.commit,
        examplesCommit: examplesIndex.source.commit,
      },
      providers: [...usedProviders].sort(),
      entries,
      stats: {
        totalFields: units.length,
        translatedFields,
        cachedFields,
        fallbackFields: pending.length,
        complete: pending.length === 0,
      },
    },
    stats: {
      locale,
      totalFields: units.length,
      translatedFields,
      cachedFields,
      fallbackFields: pending.length,
      providers: [...usedProviders].sort(),
    },
  };
};

