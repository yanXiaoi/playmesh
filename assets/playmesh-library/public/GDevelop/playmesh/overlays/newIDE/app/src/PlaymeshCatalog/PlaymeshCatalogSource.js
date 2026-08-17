// @flow
import {
  PlaymeshCatalogError,
  ensureSafeRelativePath,
  fetchCatalogArtifact,
  loadCatalogJson,
  loadRootCatalogManifest,
  parseCatalogJsonArtifact,
  validateCatalogFeatureManifest,
  validateArtifactUrl,
} from './PlaymeshCatalogRuntime';
import type {
  PlaymeshCatalogArtifact,
  PlaymeshCatalogDownload,
  PlaymeshCatalogEngine,
  PlaymeshCatalogLimits,
  PlaymeshCatalogManifest,
  PlaymeshCatalogSourceIdentity,
} from './PlaymeshCatalogRuntime';
import type {
  BehaviorShortHeader,
  BehaviorsRegistry,
  ExtensionDependency,
  ExtensionHeader,
  ExtensionShortHeader,
  ExtensionsRegistry,
  ObjectShortHeader,
  SerializedExtension,
} from '../Utils/GDevelopServices/Extension';

type MixedRecord = { +[string]: mixed };
type CatalogFeature = 'extensions' | 'examples';
type LoadOptions = {|
  signal?: ?AbortSignal,
  force?: boolean,
|};
type RawExtensionTier =
  | 'community'
  | 'experimental'
  | 'reviewed'
  | 'installed';

export type PlaymeshCatalogJsonValue =
  | null
  | boolean
  | number
  | string
  | Array<PlaymeshCatalogJsonValue>
  | PlaymeshCatalogJsonObject;
export type PlaymeshCatalogJsonObject = {
  [string]: PlaymeshCatalogJsonValue,
};

type IndexedExtensionHeader = {
  ...ExtensionHeader,
  tier: RawExtensionTier,
  artifactId: string,
};

type IndexedBehaviorHeader = {
  ...BehaviorShortHeader,
  tier: RawExtensionTier,
};

type PlaymeshExtensionViews = {|
  default: {|
    firstIds: Array<string>,
  |},
|};

type PlaymeshBehaviorViews = {|
  default: {|
    firstIds: Array<{|
      extensionName: string,
      behaviorName: string,
    |}>,
  |},
|};

type PlaymeshExtensionsIndex = {|
  schemaVersion: 1,
  catalogRevision: string,
  engine: PlaymeshCatalogEngine,
  source: PlaymeshCatalogSourceIdentity,
  version: string,
  headers: Array<IndexedExtensionHeader>,
  views: PlaymeshExtensionViews,
  behavior: {|
    headers: Array<IndexedBehaviorHeader>,
    views: PlaymeshBehaviorViews,
  |},
  artifacts: { [string]: PlaymeshCatalogArtifact },
|};

export type PlaymeshExampleFile = {|
  relativePath: string,
  declaredBytes: number,
  gitBlobOid: string,
  sha256: string,
  mediaType: string,
|};

export type PlaymeshExamplePreview = {|
  ...PlaymeshExampleFile,
  url: string,
|};

export type PlaymeshExampleHeader = {|
  id: string,
  slug: string,
  root: string,
  category: 'official-examples',
  name: string,
  shortDescription: string,
  description: string,
  tags: Array<string>,
  authors: Array<string>,
  engine: PlaymeshCatalogEngine,
  gdevelopVersion: string,
  project: PlaymeshCatalogArtifact,
  files: Array<PlaymeshExampleFile>,
  license: {|
    status: 'repository-default' | 'runtime-validation-required',
    defaultName: string,
    defaultSourceUrl: string,
    documents: Array<PlaymeshExampleFile>,
  |},
  preview: ?PlaymeshExamplePreview,
  codeSizeLevel: string,
  declaredFileCount: number,
  declaredRepositoryBytes: number,
|};

export type PlaymeshExamplesIndex = {|
  schemaVersion: 2,
  catalogRevision: string,
  engine: PlaymeshCatalogEngine,
  source: PlaymeshCatalogSourceIdentity,
  headers: Array<PlaymeshExampleHeader>,
|};

export type PlaymeshExampleProjectResource = {|
  file: string,
  name: string,
  kind: string,
  artifact: PlaymeshCatalogArtifact,
|};

export type PlaymeshVerifiedExampleLicense = {|
  status: 'open' | 'non-open' | 'unknown' | 'conflict',
  name: string,
  sourceUrl: string,
  evidenceKey: string,
  documents: Array<{|
    path: string,
    contentHash: string,
    detectedLicense: ?string,
    detectedRestrictions: Array<string>,
    hasUnresolvedPolicyClaim: boolean,
    copyrightNotices: Array<string>,
  |}>,
|};

export type PlaymeshRuntimeExampleManifest = {|
  schemaVersion: 2,
  catalogRevision: string,
  engine: PlaymeshCatalogEngine,
  id: string,
  slug: string,
  name: string,
  project: PlaymeshCatalogArtifact,
  projectDownload: {|
    bytes: ArrayBuffer,
    contentHash: string,
  |},
  projectValue: PlaymeshCatalogJsonObject,
  resources: Array<PlaymeshExampleProjectResource>,
  license: PlaymeshVerifiedExampleLicense,
  totalBytes: number,
  requestCount: number,
|};

export type PlaymeshExampleManifestResult = {|
  manifest: PlaymeshCatalogManifest,
  exampleManifest: PlaymeshRuntimeExampleManifest,
|};

const asMixedRecord = (value: mixed): ?MixedRecord => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return (value: MixedRecord);
};

const requireRecord = (value: mixed, message: string): MixedRecord => {
  const record = asMixedRecord(value);
  if (!record) {
    throw new PlaymeshCatalogError('invalid_catalog', message);
  }
  return record;
};

const requireString = (
  record: MixedRecord,
  key: string,
  message: string
): string => {
  const value = record[key];
  if (typeof value !== 'string') {
    throw new PlaymeshCatalogError('invalid_catalog', message);
  }
  return value;
};

const requireStringArray = (
  value: mixed,
  message: string
): Array<string> => {
  if (!Array.isArray(value)) {
    throw new PlaymeshCatalogError('invalid_catalog', message);
  }
  return value.map((item: mixed) => {
    if (typeof item !== 'string') {
      throw new PlaymeshCatalogError('invalid_catalog', message);
    }
    return item;
  });
};

const requireSafeInteger = (
  record: MixedRecord,
  key: string,
  message: string
): number => {
  const value = record[key];
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value) ||
    value < 0
  ) {
    throw new PlaymeshCatalogError('invalid_catalog', message);
  }
  return value;
};

const decodeJsonValue = (
  value: mixed,
  depth: number = 0
): PlaymeshCatalogJsonValue => {
  if (depth > 512) {
    throw new PlaymeshCatalogError('invalid_json', '目录 JSON 嵌套过深。');
  }
  if (
    value === null ||
    typeof value === 'boolean' ||
    typeof value === 'string'
  ) {
    return value;
  }
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (Array.isArray(value)) {
    return value.map((item: mixed) => decodeJsonValue(item, depth + 1));
  }
  const record = asMixedRecord(value);
  if (!record) {
    throw new PlaymeshCatalogError('invalid_json', '目录 JSON 包含无效字段。');
  }
  const result: PlaymeshCatalogJsonObject = {};
  Object.keys(record).forEach((key: string) => {
    result[key] = decodeJsonValue(record[key], depth + 1);
  });
  return result;
};

type RegistryHeaderBase = {|
  tier: RawExtensionTier,
  authorIds: Array<string>,
  extensionNamespace: string,
  fullName: string,
  name: string,
  version: string,
  gdevelopVersion?: string,
  url: string,
  headerUrl: string,
  tags: Array<string>,
  category: string,
  previewIconUrl: string,
  changelog?: Array<{|
    version: string,
    breaking?: string,
  |}>,
  requiredExtensions?: Array<{|
    extensionName: string,
    extensionVersion: string,
  |}>,
|};

type IndexedEventFunctionType =
  | 'StringExpression'
  | 'Expression'
  | 'Action'
  | 'Condition'
  | 'ExpressionAndCondition'
  | 'ActionWithOperator';

type IndexedEventFunction = {|
  description: string,
  fullName: string,
  functionType: IndexedEventFunctionType,
  name: string,
|};

const decodeTier = (value: mixed): RawExtensionTier => {
  switch (value) {
    case 'community':
    case 'experimental':
    case 'reviewed':
    case 'installed':
      return value;
    default:
      throw new PlaymeshCatalogError(
        'invalid_catalog',
        '扩展目录 tier 无效。'
      );
  }
};

const decodeEventFunctionType = (
  value: mixed
): IndexedEventFunctionType => {
  switch (value) {
    case 'StringExpression':
    case 'Expression':
    case 'Action':
    case 'Condition':
    case 'ExpressionAndCondition':
    case 'ActionWithOperator':
      return value;
    default:
      throw new PlaymeshCatalogError(
        'invalid_catalog',
        '扩展目录函数类型无效。'
      );
  }
};

const decodeEventFunction = (value: mixed): IndexedEventFunction => {
  const record = requireRecord(value, '扩展目录函数记录无效。');
  return {
    description: requireString(record, 'description', '扩展函数描述缺失。'),
    fullName: requireString(record, 'fullName', '扩展函数全名缺失。'),
    functionType: decodeEventFunctionType(record.functionType),
    name: requireString(record, 'name', '扩展函数名缺失。'),
  };
};

const decodeOptionalEventFunctions = (
  value: mixed
): void | Array<IndexedEventFunction> => {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new PlaymeshCatalogError('invalid_catalog', '扩展函数列表无效。');
  }
  return value.map((item: mixed) => decodeEventFunction(item));
};

const decodeOptionalBehaviors = (
  value: mixed
): void | Array<{|
  description: string,
  fullName: string,
  name: string,
  objectType: string,
  eventsFunctions: Array<IndexedEventFunction>,
|}> => {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new PlaymeshCatalogError('invalid_catalog', '扩展行为列表无效。');
  }
  return value.map((item: mixed) => {
    const record = requireRecord(item, '扩展行为记录无效。');
    return {
      description: requireString(record, 'description', '扩展行为描述缺失。'),
      fullName: requireString(record, 'fullName', '扩展行为全名缺失。'),
      name: requireString(record, 'name', '扩展行为名缺失。'),
      objectType: requireString(record, 'objectType', '扩展行为对象类型缺失。'),
      eventsFunctions:
        decodeOptionalEventFunctions(record.eventsFunctions) || [],
    };
  });
};

const decodeOptionalObjects = (
  value: mixed
): void | Array<{|
  description: string,
  fullName: string,
  name: string,
  defaultName: string,
  eventsFunctions: Array<IndexedEventFunction>,
|}> => {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new PlaymeshCatalogError('invalid_catalog', '扩展对象列表无效。');
  }
  return value.map((item: mixed) => {
    const record = requireRecord(item, '扩展对象记录无效。');
    return {
      description: requireString(record, 'description', '扩展对象描述缺失。'),
      fullName: requireString(record, 'fullName', '扩展对象全名缺失。'),
      name: requireString(record, 'name', '扩展对象名缺失。'),
      defaultName: requireString(record, 'defaultName', '扩展对象默认名缺失。'),
      eventsFunctions:
        decodeOptionalEventFunctions(record.eventsFunctions) || [],
    };
  });
};

const decodeRegistryHeaderBase = (record: MixedRecord): RegistryHeaderBase => {
  const gdevelopVersion = record.gdevelopVersion;
  const changelogValue = record.changelog;
  const requiredExtensionsValue = record.requiredExtensions;
  if (
    gdevelopVersion !== undefined &&
    typeof gdevelopVersion !== 'string'
  ) {
    throw new PlaymeshCatalogError('invalid_catalog', '扩展内核版本无效。');
  }
  let changelog: void | Array<{|
    version: string,
    breaking?: string,
  |}>;
  if (changelogValue !== undefined) {
    if (!Array.isArray(changelogValue)) {
      throw new PlaymeshCatalogError('invalid_catalog', '扩展变更记录无效。');
    }
    changelog = changelogValue.map((item: mixed) => {
      const entry = requireRecord(item, '扩展变更记录无效。');
      const breaking = entry.breaking;
      if (breaking !== undefined && typeof breaking !== 'string') {
        throw new PlaymeshCatalogError('invalid_catalog', '扩展破坏性说明无效。');
      }
      return {
        version: requireString(entry, 'version', '扩展变更版本缺失。'),
        breaking,
      };
    });
  }
  let requiredExtensions: void | Array<{|
    extensionName: string,
    extensionVersion: string,
  |}>;
  if (requiredExtensionsValue !== undefined) {
    if (!Array.isArray(requiredExtensionsValue)) {
      throw new PlaymeshCatalogError('invalid_catalog', '扩展依赖列表无效。');
    }
    requiredExtensions = requiredExtensionsValue.map((item: mixed) => {
      const dependency = requireRecord(item, '扩展依赖记录无效。');
      return {
        extensionName: requireString(
          dependency,
          'extensionName',
          '扩展依赖名称缺失。'
        ),
        extensionVersion: requireString(
          dependency,
          'extensionVersion',
          '扩展依赖版本缺失。'
        ),
      };
    });
  }
  return {
    tier: decodeTier(record.tier),
    authorIds: requireStringArray(record.authorIds, '扩展作者列表无效。'),
    extensionNamespace: requireString(
      record,
      'extensionNamespace',
      '扩展命名空间缺失。'
    ),
    fullName: requireString(record, 'fullName', '扩展全名缺失。'),
    name: requireString(record, 'name', '扩展名缺失。'),
    version: requireString(record, 'version', '扩展版本缺失。'),
    gdevelopVersion,
    url: requireString(record, 'url', '扩展 URL 缺失。'),
    headerUrl: requireString(record, 'headerUrl', '扩展 header URL 缺失。'),
    tags: requireStringArray(record.tags, '扩展标签列表无效。'),
    category: requireString(record, 'category', '扩展分类缺失。'),
    previewIconUrl: requireString(
      record,
      'previewIconUrl',
      '扩展预览图标缺失。'
    ),
    changelog,
    requiredExtensions,
  };
};

const decodeExtensionHeader = (value: mixed): IndexedExtensionHeader => {
  const record = requireRecord(value, '扩展目录 header 无效。');
  return {
    ...decodeRegistryHeaderBase(record),
    shortDescription: requireString(
      record,
      'shortDescription',
      '扩展短描述缺失。'
    ),
    eventsBasedBehaviorsCount: requireSafeInteger(
      record,
      'eventsBasedBehaviorsCount',
      '扩展行为数量无效。'
    ),
    eventsFunctionsCount: requireSafeInteger(
      record,
      'eventsFunctionsCount',
      '扩展函数数量无效。'
    ),
    eventsBasedBehaviors: decodeOptionalBehaviors(record.eventsBasedBehaviors),
    eventsFunctions: decodeOptionalEventFunctions(record.eventsFunctions),
    eventsBasedObjects: decodeOptionalObjects(record.eventsBasedObjects),
    helpPath: requireString(record, 'helpPath', '扩展帮助路径缺失。'),
    description: requireString(record, 'description', '扩展描述缺失。'),
    iconUrl: requireString(record, 'iconUrl', '扩展图标缺失。'),
    artifactId: requireString(record, 'artifactId', '扩展制品标识缺失。'),
  };
};

const decodeBehaviorHeader = (value: mixed): IndexedBehaviorHeader => {
  const record = requireRecord(value, '行为目录 header 无效。');
  const isDeprecated = record.isDeprecated;
  if (isDeprecated !== undefined && typeof isDeprecated !== 'boolean') {
    throw new PlaymeshCatalogError('invalid_catalog', '行为废弃标记无效。');
  }
  return {
    ...decodeRegistryHeaderBase(record),
    description: requireString(record, 'description', '行为描述缺失。'),
    extensionName: requireString(record, 'extensionName', '行为扩展名缺失。'),
    objectType: requireString(record, 'objectType', '行为对象类型缺失。'),
    allRequiredBehaviorTypes: requireStringArray(
      record.allRequiredBehaviorTypes,
      '行为依赖列表无效。'
    ),
    type: '',
    isDeprecated,
  };
};

const assertFeatureEnvelope = (
  record: MixedRecord,
  schemaVersion: 1 | 2,
  manifest: PlaymeshCatalogManifest,
  feature: CatalogFeature
): PlaymeshCatalogSourceIdentity => {
  const engine = asMixedRecord(record.engine);
  const source = asMixedRecord(record.source);
  const expectedSource = manifest.sources[feature];
  if (
    record.schemaVersion !== schemaVersion ||
    record.catalogRevision !== manifest.catalogRevision ||
    !engine ||
    engine.version !== manifest.engine.version ||
    !source ||
    source.repository !== expectedSource.repository ||
    source.commit !== expectedSource.commit ||
    source.rootTreeSha !== expectedSource.rootTreeSha
  ) {
    throw new PlaymeshCatalogError(
      'incompatible_feature',
      '本地目录分片与固定内核来源不一致。'
    );
  }
  return expectedSource;
};

const decodeExtensionViews = (
  value: mixed
): PlaymeshExtensionViews => {
  const views = requireRecord(value, '扩展目录视图无效。');
  const defaultView = requireRecord(views.default, '扩展默认视图无效。');
  return {
    default: {
      firstIds: requireStringArray(
        defaultView.firstIds,
        '扩展默认视图标识无效。'
      ),
    },
  };
};

const decodeBehaviorViews = (
  value: mixed
): PlaymeshBehaviorViews => {
  const views = requireRecord(value, '行为目录视图无效。');
  const defaultView = requireRecord(views.default, '行为默认视图无效。');
  const firstIds = defaultView.firstIds;
  if (!Array.isArray(firstIds)) {
    throw new PlaymeshCatalogError('invalid_catalog', '行为视图标识无效。');
  }
  return {
    default: {
      firstIds: firstIds.map((item: mixed) => {
        const record = requireRecord(item, '行为视图标识无效。');
        return {
          extensionName: requireString(
            record,
            'extensionName',
            '行为视图扩展名缺失。'
          ),
          behaviorName: requireString(
            record,
            'behaviorName',
            '行为视图名称缺失。'
          ),
        };
      }),
    },
  };
};

const decodeArtifacts = (
  value: mixed
): { [string]: PlaymeshCatalogArtifact } => {
  const record = requireRecord(value, '扩展制品映射无效。');
  const artifacts: { [string]: PlaymeshCatalogArtifact } = {};
  Object.keys(record).forEach((id: string) => {
    const artifact = validateArtifactUrl(record[id]);
    if (artifact.id !== id) {
      throw new PlaymeshCatalogError('invalid_catalog', '扩展制品标识不匹配。');
    }
    artifacts[id] = artifact;
  });
  return artifacts;
};

const decodeExtensionsIndex = (
  value: mixed,
  manifest: PlaymeshCatalogManifest
): PlaymeshExtensionsIndex => {
  const record = requireRecord(value, '扩展目录分片无效。');
  const source = assertFeatureEnvelope(record, 1, manifest, 'extensions');
  const headers = record.headers;
  const behavior = requireRecord(record.behavior, '行为目录分片无效。');
  const behaviorHeaders = behavior.headers;
  if (!Array.isArray(headers) || !Array.isArray(behaviorHeaders)) {
    throw new PlaymeshCatalogError('invalid_catalog', '扩展目录 header 列表无效。');
  }
  return {
    schemaVersion: 1,
    catalogRevision: manifest.catalogRevision,
    engine: manifest.engine,
    source,
    version: requireString(record, 'version', '扩展目录版本缺失。'),
    headers: headers.map((header: mixed) => decodeExtensionHeader(header)),
    views: decodeExtensionViews(record.views),
    behavior: {
      headers: behaviorHeaders.map((header: mixed) =>
        decodeBehaviorHeader(header)
      ),
      views: decodeBehaviorViews(behavior.views),
    },
    artifacts: decodeArtifacts(record.artifacts),
  };
};

const decodeExampleFile = (value: mixed): PlaymeshExampleFile => {
  const record = requireRecord(value, '示例文件记录无效。');
  const gitBlobOid = requireString(
    record,
    'gitBlobOid',
    '示例 Git blob 标识缺失。'
  );
  if (!/^[a-f0-9]{40}$/.test(gitBlobOid)) {
    throw new PlaymeshCatalogError('invalid_catalog', '示例 Git blob 标识无效。');
  }
  const sha256 = requireString(record, 'sha256', '示例 SHA-256 缺失。');
  if (!/^[a-f0-9]{64}$/.test(sha256)) {
    throw new PlaymeshCatalogError('invalid_catalog', '示例 SHA-256 无效。');
  }
  return {
    relativePath: ensureSafeRelativePath(record.relativePath),
    declaredBytes: requireSafeInteger(
      record,
      'declaredBytes',
      '示例文件大小无效。'
    ),
    gitBlobOid,
    sha256,
    mediaType: requireString(record, 'mediaType', '示例文件 MIME 缺失。'),
  };
};

const decodeExampleHeader = (
  value: mixed,
  manifest: PlaymeshCatalogManifest,
  source: PlaymeshCatalogSourceIdentity
): PlaymeshExampleHeader => {
  const record = requireRecord(value, '示例 header 无效。');
  const id = requireString(record, 'id', '示例标识缺失。');
  const slug = requireString(record, 'slug', '示例 slug 缺失。');
  const project = validateArtifactUrl(record.project);
  const filesValue = record.files;
  const licenseRecord = requireRecord(record.license, '示例许可声明无效。');
  const documentsValue = licenseRecord.documents;
  const engineRecord = requireRecord(record.engine, '示例内核声明无效。');
  if (
    id !== slug ||
    record.root !== `examples/${slug}` ||
    record.category !== 'official-examples' ||
    engineRecord.version !== manifest.engine.version ||
    project.repository !== source.repository ||
    project.commit !== source.commit ||
    project.rootTreeSha !== source.rootTreeSha ||
    project.kind !== 'example-project' ||
    !Array.isArray(filesValue) ||
    (licenseRecord.status !== 'runtime-validation-required' &&
      licenseRecord.status !== 'repository-default') ||
    !Array.isArray(documentsValue)
  ) {
    throw new PlaymeshCatalogError('invalid_catalog', '示例 header 字段无效。');
  }
  const previewValue = record.preview;
  let preview: ?PlaymeshExamplePreview = null;
  if (previewValue !== null && previewValue !== undefined) {
    const previewRecord = requireRecord(previewValue, '示例预览记录无效。');
    preview = {
      ...decodeExampleFile(previewRecord),
      url: requireString(previewRecord, 'url', '示例预览 URL 缺失。'),
    };
  }
  const codeSizeLevel = requireString(
    record,
    'codeSizeLevel',
    '示例代码规模缺失。'
  );
  return {
    id,
    slug,
    root: `examples/${slug}`,
    category: 'official-examples',
    name: requireString(record, 'name', '示例名称缺失。'),
    shortDescription: requireString(
      record,
      'shortDescription',
      '示例短描述缺失。'
    ),
    description: requireString(record, 'description', '示例描述缺失。'),
    tags: requireStringArray(record.tags, '示例标签无效。'),
    authors: requireStringArray(record.authors, '示例作者无效。'),
    engine: manifest.engine,
    gdevelopVersion: requireString(
      record,
      'gdevelopVersion',
      '示例内核版本缺失。'
    ),
    project,
    files: filesValue.map((file: mixed) => decodeExampleFile(file)),
    license: {
      status:
        licenseRecord.status === 'repository-default'
          ? 'repository-default'
          : 'runtime-validation-required',
      defaultName: requireString(
        licenseRecord,
        'defaultName',
        '示例默认许可缺失。'
      ),
      defaultSourceUrl: requireString(
        licenseRecord,
        'defaultSourceUrl',
        '示例许可来源缺失。'
      ),
      documents: documentsValue.map((file: mixed) =>
        decodeExampleFile(file)
      ),
    },
    preview,
    codeSizeLevel,
    declaredFileCount: requireSafeInteger(
      record,
      'declaredFileCount',
      '示例文件数量无效。'
    ),
    declaredRepositoryBytes: requireSafeInteger(
      record,
      'declaredRepositoryBytes',
      '示例仓库大小无效。'
    ),
  };
};

const decodeExamplesIndex = (
  value: mixed,
  manifest: PlaymeshCatalogManifest
): PlaymeshExamplesIndex => {
  const record = requireRecord(value, '示例目录分片无效。');
  const source = assertFeatureEnvelope(record, 2, manifest, 'examples');
  const headersValue = record.headers;
  if (!Array.isArray(headersValue)) {
    throw new PlaymeshCatalogError('invalid_catalog', '示例 header 列表无效。');
  }
  return {
    schemaVersion: 2,
    catalogRevision: manifest.catalogRevision,
    engine: manifest.engine,
    source,
    headers: headersValue.map((header: mixed) =>
      decodeExampleHeader(header, manifest, source)
    ),
  };
};

let rootManifestPromise: ?Promise<PlaymeshCatalogManifest> = null;
let extensionsIndexPromise: ?Promise<PlaymeshExtensionsIndex> = null;
let examplesIndexPromise: ?Promise<PlaymeshExamplesIndex> = null;

const textDecoder = new TextDecoder('utf-8', { fatal: true });

const getManifestUrl = (): URL => {
  const baseUri = document.baseURI;
  if (typeof baseUri !== 'string' || !baseUri) {
    throw new PlaymeshCatalogError('invalid_base_url', '当前页面基础地址无效。');
  }
  return new URL('./playmesh/catalog/catalog-manifest.json', baseUri);
};

const loadManifest = ({
  signal,
  force = false,
}: LoadOptions = {}): Promise<PlaymeshCatalogManifest> => {
  if (force) rootManifestPromise = null;
  if (rootManifestPromise) return rootManifestPromise;
  const url = getManifestUrl();
  const nextPromise = loadRootCatalogManifest({
    url: url.href,
    cacheKey: 'root:gdevelop-v5.6.276',
    signal,
  }).catch(error => {
    rootManifestPromise = null;
    throw error;
  });
  rootManifestPromise = nextPromise;
  return nextPromise;
};

const loadFeature = async (
  feature: CatalogFeature,
  { signal, force = false }: LoadOptions = {}
): Promise<{|
  manifest: PlaymeshCatalogManifest,
  value: mixed,
|}> => {
  const manifest = await loadManifest({ signal, force });
  const descriptor =
    feature === 'extensions'
      ? manifest.features.extensions
      : manifest.features.examples;
  const manifestUrl = getManifestUrl();
  const featureManifestValue = await loadCatalogJson({
    baseUrl: new URL('./', manifestUrl).href,
    descriptor,
    cacheKey: `${feature}:manifest:${manifest.catalogRevision}:${descriptor.sha256}`,
    limits: manifest.limits,
    signal,
  });
  const featureManifest = validateCatalogFeatureManifest({
    value: featureManifestValue,
    feature,
    rootManifest: manifest,
  });
  const value = await loadCatalogJson({
    baseUrl: new URL('./', manifestUrl).href,
    descriptor: featureManifest.index,
    cacheKey: `${feature}:index:${manifest.catalogRevision}:${
      featureManifest.index.sha256
    }`,
    limits: manifest.limits,
    signal,
  });
  return { manifest, value };
};

export const loadPlaymeshExtensionsIndex = ({
  signal,
  force = false,
}: LoadOptions = {}): Promise<PlaymeshExtensionsIndex> => {
  if (force) extensionsIndexPromise = null;
  if (extensionsIndexPromise) return extensionsIndexPromise;
  const nextPromise = loadFeature('extensions', { signal, force })
    .then(({ manifest, value }) => decodeExtensionsIndex(value, manifest))
    .catch(error => {
      extensionsIndexPromise = null;
      throw error;
    });
  extensionsIndexPromise = nextPromise;
  return nextPromise;
};

export const loadPlaymeshExamplesIndex = ({
  signal,
  force = false,
}: LoadOptions = {}): Promise<PlaymeshExamplesIndex> => {
  if (force) examplesIndexPromise = null;
  if (examplesIndexPromise) return examplesIndexPromise;
  const nextPromise = loadFeature('examples', { signal, force })
    .then(({ manifest, value }) => decodeExamplesIndex(value, manifest))
    .catch(error => {
      examplesIndexPromise = null;
      throw error;
    });
  examplesIndexPromise = nextPromise;
  return nextPromise;
};

const adaptExtensionTier = (
  tier: RawExtensionTier
): 'experimental' | 'reviewed' | 'installed' =>
  tier === 'community' ? 'experimental' : tier;

const adaptExtensionHeader = (
  header: IndexedExtensionHeader
): ExtensionHeader => {
  const { artifactId, ...extensionHeader } = header;
  return {
    ...extensionHeader,
    tier: adaptExtensionTier(header.tier),
  };
};

const adaptExtensionShortHeader = (
  header: IndexedExtensionHeader
): ExtensionShortHeader => {
  const {
    artifactId,
    description,
    iconUrl,
    ...extensionShortHeader
  } = header;
  return {
    ...extensionShortHeader,
    tier: adaptExtensionTier(header.tier),
  };
};

const resolveCatalogExtensionName = (
  header: ExtensionShortHeader | BehaviorShortHeader | ObjectShortHeader
): string =>
  'extensionName' in header && header.extensionName
    ? header.extensionName
    : header.name;

const assertArtifactMatchesSource = (
  artifact: PlaymeshCatalogArtifact,
  source: PlaymeshCatalogSourceIdentity
): void => {
  if (
    !artifact ||
    artifact.repository !== source.repository ||
    artifact.commit !== source.commit ||
    artifact.rootTreeSha !== source.rootTreeSha
  ) {
    throw new PlaymeshCatalogError(
      'invalid_artifact',
      '目录正文没有绑定到当前固定 commit/root tree。'
    );
  }
};

type CreateExampleArtifactOptions = {|
  header: PlaymeshExampleHeader,
  source: PlaymeshCatalogSourceIdentity,
  file: PlaymeshExampleFile,
  kind: 'example-resource' | 'example-license' | 'example-preview',
|};

const createExampleArtifact = ({
  header,
  source,
  file,
  kind,
}: CreateExampleArtifactOptions): PlaymeshCatalogArtifact => {
  const relativePath = ensureSafeRelativePath(file.relativePath);
  const sourcePath = `${header.root}/${relativePath}`;
  return {
    id: `example:${header.slug}:${kind}:${file.gitBlobOid}`,
    kind,
    repository: source.repository,
    commit: source.commit,
    rootTreeSha: source.rootTreeSha,
    path: sourcePath,
    url: `https://raw.githubusercontent.com/${source.repository}/${
      source.commit
    }/${sourcePath
      .split('/')
      .map(segment => encodeURIComponent(segment))
      .join('/')}`,
    declaredBytes: file.declaredBytes,
    gitBlobOid: file.gitBlobOid,
    sha256: file.sha256,
    mediaType: file.mediaType,
  };
};

export const getPlaymeshExtensionsRegistry = async (): Promise<
  ExtensionsRegistry
> => {
  try {
    const index = await loadPlaymeshExtensionsIndex();
    return {
      version: index.version,
      headers: index.headers.map((header: IndexedExtensionHeader) =>
        adaptExtensionShortHeader(header)
      ),
      views: index.views,
    };
  } catch (error) {
    // The optional catalog must never mark the current project as having an
    // extension loading error or block save/preview/publish.
    console.warn('Playmesh extension catalog is unavailable.', error);
    return {
      version: '0.0.1-playmesh-unavailable',
      headers: [],
      views: { default: { firstIds: [] } },
    };
  }
};

export const getPlaymeshBehaviorsRegistry = async (): Promise<
  BehaviorsRegistry
> => {
  try {
    const index = await loadPlaymeshExtensionsIndex();
    const gd = global.gd;
    return {
      headers: index.behavior.headers.map(
        (header: IndexedBehaviorHeader): BehaviorShortHeader => ({
          ...header,
          tier: adaptExtensionTier(header.tier),
          type: gd.PlatformExtension.getBehaviorFullType(
            header.extensionNamespace || header.extensionName,
            header.name
          ),
        })
      ),
      views: index.behavior.views,
    };
  } catch (error) {
    console.warn('Playmesh behavior catalog is unavailable.', error);
    return {
      headers: [],
      views: { default: { firstIds: [] } },
    };
  }
};

export const getPlaymeshExtensionHeader = async (
  extensionShortHeader:
    | ExtensionShortHeader
    | BehaviorShortHeader
    | ObjectShortHeader
): Promise<ExtensionHeader> => {
  const index = await loadPlaymeshExtensionsIndex();
  const extensionName = resolveCatalogExtensionName(extensionShortHeader);
  const header = index.headers.find(
    candidate => candidate.name === extensionName
  );
  if (!header) {
    throw new PlaymeshCatalogError('not_found', '扩展已不在当前固定目录中。');
  }
  return adaptExtensionHeader(header);
};

export const getPlaymeshExtension = async (
  extensionHeader: ExtensionShortHeader | BehaviorShortHeader
): Promise<SerializedExtension> => {
  const index = await loadPlaymeshExtensionsIndex();
  const extensionName = resolveCatalogExtensionName(extensionHeader);
  const header = index.headers.find(candidate => candidate.name === extensionName);
  const artifact = header && index.artifacts[header.artifactId];
  if (!header || !artifact) {
    throw new PlaymeshCatalogError('not_found', '扩展正文描述缺失。');
  }
  assertArtifactMatchesSource(artifact, index.source);
  const manifest = await loadManifest();
  const { value } = await parseCatalogJsonArtifact({
    artifact,
    limits: manifest.limits,
  });
  const decodedExtension = decodeJsonValue(value);
  if (
    !decodedExtension ||
    typeof decodedExtension !== 'object' ||
    Array.isArray(decodedExtension)
  ) {
    throw new PlaymeshCatalogError('invalid_extension', '扩展正文不是 JSON 对象。');
  }
  const extension: PlaymeshCatalogJsonObject = decodedExtension;
  const name = extension.name;
  const version = extension.version;
  const gdevelopVersion = extension.gdevelopVersion;
  if (
    typeof name !== 'string' ||
    name !== header.name ||
    version !== header.version ||
    (gdevelopVersion || '') !== header.gdevelopVersion
  ) {
    throw new PlaymeshCatalogError('invalid_extension', '扩展正文和固定索引不一致。');
  }
  const tags = extension.tags;
  if (typeof tags === 'string') {
    const normalizedTags: Array<PlaymeshCatalogJsonValue> = tags
      .split(',')
      .reduce(
        (result: Array<PlaymeshCatalogJsonValue>, tag: string) => {
          const normalizedTag = tag.trim().toLowerCase();
          if (normalizedTag) result.push(normalizedTag);
          return result;
        },
        []
      );
    extension.tags = normalizedTags;
  }
  const requiredExtensionsValue = extension.requiredExtensions;
  let requiredExtensions: void | Array<ExtensionDependency>;
  if (requiredExtensionsValue !== undefined) {
    if (!Array.isArray(requiredExtensionsValue)) {
      throw new PlaymeshCatalogError(
        'invalid_extension',
        '扩展依赖声明无效。'
      );
    }
    requiredExtensions = requiredExtensionsValue.map((value: mixed) => {
      const dependency = requireRecord(value, '扩展依赖声明无效。');
      return {
        extensionName: requireString(
          dependency,
          'extensionName',
          '扩展依赖名称缺失。'
        ),
        extensionVersion: requireString(
          dependency,
          'extensionVersion',
          '扩展依赖版本缺失。'
        ),
      };
    });
  }
  const serializedExtension: SerializedExtension = requiredExtensions
    ? { name, requiredExtensions }
    : { name };
  Object.keys(extension).forEach((key: string) => {
    if (key === 'name' || key === 'requiredExtensions') return;
    Object.defineProperty(serializedExtension, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: extension[key],
    });
  });
  return serializedExtension;
};

const normalizeExampleResourcePath = (value: mixed): ?string => {
  if (typeof value !== 'string' || !value) {
    throw new PlaymeshCatalogError('invalid_project', '示例资源路径为空。');
  }
  if (value.startsWith('data:')) return null;
  const normalized = value.replaceAll('\\', '/').replace(/^\.\//, '');
  if (/^[a-z][a-z\d+.-]*:/i.test(normalized)) {
    throw new PlaymeshCatalogError(
      'external_resource',
      '示例引用了外部 URL 或绝对资源，拒绝导入。'
    );
  }
  return ensureSafeRelativePath(normalized);
};

type ValidatedExampleProject = {|
  value: PlaymeshCatalogJsonObject,
  properties: PlaymeshCatalogJsonObject,
  resources: Array<PlaymeshCatalogJsonObject>,
|};

const validateProjectShape = (value: mixed): ValidatedExampleProject => {
  const decodedProject = decodeJsonValue(value);
  if (
    !decodedProject ||
    typeof decodedProject !== 'object' ||
    Array.isArray(decodedProject)
  ) {
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例项目不符合 GDevelop 5 项目结构。'
    );
  }
  const project: PlaymeshCatalogJsonObject = decodedProject;
  const propertiesValue = project.properties;
  const propertiesRecord = asMixedRecord(propertiesValue);
  const resourcesContainer = asMixedRecord(project.resources);
  const resourcesValue = resourcesContainer
    ? resourcesContainer.resources
    : null;
  if (
    !propertiesRecord ||
    !Array.isArray(resourcesValue) ||
    !Array.isArray(project.layouts)
  ) {
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例项目不符合 GDevelop 5 项目结构。'
    );
  }
  if (
    !propertiesValue ||
    typeof propertiesValue !== 'object' ||
    Array.isArray(propertiesValue)
  ) {
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例项目 properties 无效。'
    );
  }
  const properties: PlaymeshCatalogJsonObject = propertiesValue;
  const resources = resourcesValue.map((resource: mixed) => {
    const decodedResource = decodeJsonValue(resource);
    if (
      !decodedResource ||
      typeof decodedResource !== 'object' ||
      Array.isArray(decodedResource)
    ) {
      throw new PlaymeshCatalogError(
        'invalid_project_schema',
        '示例资源记录无效。'
      );
    }
    return decodedResource;
  });
  const gdVersion = asMixedRecord(project.gdVersion);
  const major = gdVersion ? gdVersion.major : null;
  const minor = gdVersion ? gdVersion.minor : null;
  if (
    gdVersion &&
    (typeof major !== 'number' ||
      !Number.isInteger(major) ||
      typeof minor !== 'number' ||
      !Number.isInteger(minor) ||
      major > 5 ||
      (major === 5 && minor > 6))
  ) {
    throw new PlaymeshCatalogError(
      'incompatible_project',
      '示例项目需要更高版本的 GDevelop 内核。'
    );
  }
  const extensions = propertiesRecord.extensions || [];
  if (
    !Array.isArray(extensions) ||
    extensions.length > 512 ||
    extensions.some(
      (extension: mixed) => {
        const record = asMixedRecord(extension);
        const name = record ? record.name : null;
        return (
          typeof name !== 'string' ||
          !/^[A-Za-z][A-Za-z0-9_]*$/.test(name)
        );
      }
    )
  ) {
    throw new PlaymeshCatalogError(
      'invalid_project_dependencies',
      '示例项目扩展依赖声明无效。'
    );
  }
  return { value: project, properties, resources };
};

type ValidateExampleHeaderOptions = {|
  header: PlaymeshExampleHeader,
  index: PlaymeshExamplesIndex,
  manifest: PlaymeshCatalogManifest,
|};

const validateExampleHeader = ({
  header,
  index,
  manifest,
}: ValidateExampleHeaderOptions): Map<string, PlaymeshExampleFile> => {
  if (
    !header ||
    typeof header.slug !== 'string' ||
    !header.slug ||
    header.id !== header.slug ||
    header.root !== `examples/${header.slug}` ||
    header.category !== 'official-examples' ||
    !header.engine ||
    header.engine.version !== manifest.engine.version ||
    !Array.isArray(header.files) ||
    !header.project ||
    !header.license ||
    !Array.isArray(header.license.documents)
  ) {
    throw new PlaymeshCatalogError('invalid_example', '示例索引字段无效。');
  }
  assertArtifactMatchesSource(header.project, index.source);
  if (!header.project.path.startsWith(`${header.root}/`)) {
    throw new PlaymeshCatalogError('invalid_example', '示例项目路径越界。');
  }
  const files: Map<string, PlaymeshExampleFile> = new Map();
  for (const file of header.files) {
    const relativePath = ensureSafeRelativePath(file.relativePath);
    if (
      files.has(relativePath) ||
      !Number.isSafeInteger(file.declaredBytes) ||
      file.declaredBytes < 0 ||
      !/^[a-f0-9]{40}$/.test(file.gitBlobOid || '') ||
      !/^[a-f0-9]{64}$/.test(file.sha256 || '') ||
      typeof file.mediaType !== 'string' ||
      !file.mediaType
    ) {
      throw new PlaymeshCatalogError('invalid_example', '示例文件 tree 重复或缺失。');
    }
    files.set(relativePath, file);
  }
  const projectRelativePath = header.project.path.slice(header.root.length + 1);
  const projectFile = files.get(projectRelativePath);
  if (
    !projectFile ||
    projectFile.declaredBytes !== header.project.declaredBytes ||
    projectFile.gitBlobOid !== header.project.gitBlobOid ||
    projectFile.sha256 !== header.project.sha256 ||
    projectFile.mediaType !== 'application/json'
  ) {
    throw new PlaymeshCatalogError('invalid_example', '示例项目不在固定 Git tree 中。');
  }
  return files;
};

// This is deliberately an auditable allowlist, not a general-purpose legal
// classifier. Unrecognised or contradictory wording is never presented as an
// open licence merely because it resembles one.
const detectNamedLicense = (text: string): ?string => {
  if (/\bMIT(?: license)?\b/i.test(text)) return 'MIT';
  if (/\bCC0(?:[- ]?1\.0)?\b|creative commons zero/i.test(text)) return 'CC0-1.0';
  if (/\bCC[- ]BY[- ](?:NC|ND)(?:[- ](?:SA|ND))?/i.test(text)) return null;
  if (/\bCC[- ]BY[- ]SA(?:[- ]?4\.0)?\b/i.test(text)) return 'CC-BY-SA-4.0';
  if (/\bCC[- ]BY(?:[- ]?4\.0)?\b/i.test(text)) return 'CC-BY-4.0';
  if (/\bApache(?: license)?(?:,? version)? 2\.0\b/i.test(text)) return 'Apache-2.0';
  if (/\bBSD(?:[- ]?3[- ]Clause)?\b/i.test(text)) return 'BSD-3-Clause';
  if (/\bpublic domain\b/i.test(text)) return 'Public-Domain';
  return null;
};

const detectExplicitRestrictions = (text: string): Array<string> => {
  const restrictions = [];
  if (
    /\b(?:no|do not|may not|must not)\s+(?:re-?distribut|share|republish)|\bre-?distribution\s+(?:is\s+)?(?:prohibited|forbidden|not permitted)\b/i.test(
      text
    )
  ) {
    restrictions.push('redistribution-restricted');
  }
  if (
    /\b(?:no|do not|may not|must not)\s+(?:modify|adapt|create derivative)|\bderivative works?\s+(?:are\s+)?(?:prohibited|forbidden|not permitted)\b/i.test(
      text
    )
  ) {
    restrictions.push('derivatives-restricted');
  }
  if (/\bnon[- ]commercial\b|\bnot for commercial use\b/i.test(text)) {
    restrictions.push('non-commercial-only');
  }
  if (/\bCC[- ]BY[- ]NC(?:[- ](?:SA|ND))?/i.test(text)) {
    restrictions.push('non-commercial-only');
  }
  if (/\bCC[- ]BY[- ]ND\b/i.test(text)) {
    restrictions.push('derivatives-restricted');
  }
  if (/\bproprietary\b|\bpersonal use only\b/i.test(text)) {
    restrictions.push('proprietary-or-personal-use');
  }
  return restrictions;
};

const detectDefaultOpenLicense = (value: string): ?string => {
  // The locked repository declaration currently uses “MIT unless an example
  // directory states otherwise”. Only this exact open licence family is
  // accepted as the no-local-policy fallback.
  return /^MIT(?:\s+license)?(?:\s+unless\b[\s\S]*)?$/i.test(value.trim())
    ? 'MIT'
    : null;
};

const extractCopyrightNotices = (text: string): Array<string> =>
  text
    .split(/\r?\n/)
    .map(line => line.replace(/\s+/g, ' ').trim())
    .filter(line => /\bcopyright\b|©/i.test(line))
    .filter((line, index, lines) => line && lines.indexOf(line) === index)
    .slice(0, 3)
    .map(line => line.slice(0, 240));

export const getPlaymeshExampleLicensePreviewStatus = (
  header: PlaymeshExampleHeader
): 'open' | 'pending' | 'unknown' => {
  if (
    header.license.status === 'repository-default' &&
    detectDefaultOpenLicense(header.license.defaultName)
  ) {
    return 'open';
  }
  return header.license.status === 'runtime-validation-required'
    ? 'pending'
    : 'unknown';
};

type ValidateExampleLicenseOptions = {|
  header: PlaymeshExampleHeader,
  index: PlaymeshExamplesIndex,
  files: Map<string, PlaymeshExampleFile>,
  limits: PlaymeshCatalogLimits,
  signal?: ?AbortSignal,
|};

const validateExampleLicense = async ({
  header,
  index,
  files,
  limits,
  signal,
}: ValidateExampleLicenseOptions): Promise<PlaymeshVerifiedExampleLicense> => {
  const documents = header.license.documents;
  if (documents.length > limits.licenseFileCount) {
    throw new PlaymeshCatalogError('license_too_large', '示例许可文件数量超限。');
  }
  let declaredBytes = 0;
  const licenseFiles: Array<PlaymeshExampleFile> = documents.map(
    (document: PlaymeshExampleFile) => {
      const relativePath = ensureSafeRelativePath(document.relativePath);
      const file = files.get(relativePath);
      if (
        !file ||
        file.declaredBytes !== document.declaredBytes ||
        file.gitBlobOid !== document.gitBlobOid ||
        file.sha256 !== document.sha256 ||
        file.mediaType !== document.mediaType
      ) {
        throw new PlaymeshCatalogError(
          'invalid_license',
          '示例许可文件不在固定 Git tree 中。'
        );
      }
      declaredBytes += file.declaredBytes;
      return file;
    }
  );
  if (
    new Set(licenseFiles.map(file => file.relativePath)).size !==
    licenseFiles.length
  ) {
    throw new PlaymeshCatalogError('invalid_license', '示例许可文件重复。');
  }
  if (declaredBytes > limits.licenseFileBytes) {
    throw new PlaymeshCatalogError('license_too_large', '示例许可内容总量超限。');
  }

  const detectedLicenses: Set<string> = new Set();
  const detectedRestrictions: Set<string> = new Set();
  let hasUnresolvedPolicyClaim = false;
  const verifiedDocuments: Array<{|
    path: string,
    contentHash: string,
    detectedLicense: ?string,
    detectedRestrictions: Array<string>,
    hasUnresolvedPolicyClaim: boolean,
    copyrightNotices: Array<string>,
  |}> = [];
  for (const file of licenseFiles) {
    const artifact = createExampleArtifact({
      header,
      source: index.source,
      file,
      kind: 'example-license',
    });
    const result = await fetchCatalogArtifact({ artifact, limits, signal });
    let text: string;
    try {
      text = textDecoder.decode(result.bytes);
    } catch (_) {
      throw new PlaymeshCatalogError(
        'invalid_license',
        '示例许可文件不是 UTF-8 文本。'
      );
    }
    const filename = file.relativePath.split('/').pop() || '';
    const detectedLicense = detectNamedLicense(text);
    const documentRestrictions = detectExplicitRestrictions(text);
    const copyrightNotices = extractCopyrightNotices(text);
    const containsPolicyClaim =
      /\b(?:license|licensed|copyright|credits?|attribution)\b|©/i.test(text);
    const isReadme = /^readme\.md$/i.test(filename);
    const unresolvedPolicyClaim =
      !detectedLicense &&
      documentRestrictions.length === 0 &&
      (!isReadme || containsPolicyClaim);
    if (detectedLicense) detectedLicenses.add(detectedLicense);
    documentRestrictions.forEach(restriction =>
      detectedRestrictions.add(restriction)
    );
    if (unresolvedPolicyClaim) hasUnresolvedPolicyClaim = true;
    verifiedDocuments.push({
      path: file.relativePath,
      contentHash: result.contentHash,
      detectedLicense,
      detectedRestrictions: documentRestrictions,
      hasUnresolvedPolicyClaim: unresolvedPolicyClaim,
      copyrightNotices,
    });
  }
  const defaultOpenLicense = detectDefaultOpenLicense(
    header.license.defaultName
  );
  const status =
    detectedRestrictions.size && detectedLicenses.size
      ? 'conflict'
      : detectedRestrictions.size
      ? 'non-open'
      : hasUnresolvedPolicyClaim
      ? 'unknown'
      : detectedLicenses.size || defaultOpenLicense
      ? 'open'
      : 'unknown';
  const licenseNames = detectedLicenses.size
    ? [...detectedLicenses].sort()
    : defaultOpenLicense
    ? [defaultOpenLicense]
    : [];
  const name = licenseNames.length
    ? licenseNames.join(' + ')
    : header.license.defaultName;
  const evidenceKey = [
    header.id,
    status,
    name,
    ...verifiedDocuments.map(document =>
      [
        document.path,
        document.contentHash,
        document.detectedLicense || '',
        document.detectedRestrictions.join(','),
        document.hasUnresolvedPolicyClaim ? 'unresolved' : 'resolved',
        document.copyrightNotices.join(','),
      ].join(':')
    ),
  ].join('|');
  return {
    status,
    name,
    sourceUrl: header.license.defaultSourceUrl,
    evidenceKey,
    documents: verifiedDocuments,
  };
};

type InspectPlaymeshExampleLicenseOptions = {|
  header: PlaymeshExampleHeader,
  signal?: ?AbortSignal,
|};

export const inspectPlaymeshExampleLicense = async ({
  header,
  signal,
}: InspectPlaymeshExampleLicenseOptions): Promise<
  PlaymeshVerifiedExampleLicense
> => {
  const [manifest, index] = await Promise.all([
    loadManifest({ signal }),
    loadPlaymeshExamplesIndex({ signal }),
  ]);
  const currentHeader = index.headers.find(
    candidate => candidate.id === header.id
  );
  if (!currentHeader) {
    throw new PlaymeshCatalogError('not_found', '示例已不在当前固定目录中。');
  }
  const files = validateExampleHeader({
    header: currentHeader,
    index,
    manifest,
  });
  return validateExampleLicense({
    header: currentHeader,
    index,
    files,
    limits: manifest.limits,
    signal,
  });
};

type BuildRuntimeExampleManifestOptions = {|
  header: PlaymeshExampleHeader,
  index: PlaymeshExamplesIndex,
  manifest: PlaymeshCatalogManifest,
  signal?: ?AbortSignal,
|};

const buildRuntimeExampleManifest = async ({
  header,
  index,
  manifest,
  signal,
}: BuildRuntimeExampleManifestOptions): Promise<
  PlaymeshRuntimeExampleManifest
> => {
  const files = validateExampleHeader({ header, index, manifest });
  const projectDownload = await parseCatalogJsonArtifact({
    artifact: header.project,
    limits: manifest.limits,
    signal,
  });
  const project = validateProjectShape(projectDownload.value);
  const resources: Array<PlaymeshExampleProjectResource> = [];
  const seenPaths: Set<string> = new Set();
  let totalBytes = projectDownload.bytes.byteLength;
  for (const resource of project.resources) {
    const relativePath = normalizeExampleResourcePath(resource.file);
    if (!relativePath || seenPaths.has(relativePath)) continue;
    seenPaths.add(relativePath);
    const file = files.get(relativePath);
    if (!file) {
      throw new PlaymeshCatalogError(
        'missing_resource',
        `示例资源不在固定 Git tree 中：${relativePath}`
      );
    }
    const artifact = createExampleArtifact({
      header,
      source: index.source,
      file,
      kind: 'example-resource',
    });
    totalBytes += Number(artifact.declaredBytes || 0);
    resources.push({
      file: relativePath,
      name: String(resource.name || relativePath),
      kind: String(resource.kind || ''),
      artifact,
    });
  }
  if (resources.length > manifest.limits.exampleResourceCount) {
    throw new PlaymeshCatalogError('too_many_resources', '示例资源数量超限。');
  }
  if (!Number.isSafeInteger(totalBytes) || totalBytes > manifest.limits.exampleTotalBytes) {
    throw new PlaymeshCatalogError('too_large', '示例下载总量超过当前设备限制。');
  }
  const license = await validateExampleLicense({
    header,
    index,
    files,
    limits: manifest.limits,
    signal,
  });
  return {
    schemaVersion: 2,
    catalogRevision: manifest.catalogRevision,
    engine: manifest.engine,
    id: header.id,
    slug: header.slug,
    name: header.name,
    project: header.project,
    projectDownload: {
      bytes: projectDownload.bytes,
      contentHash: projectDownload.contentHash,
    },
    projectValue: project.value,
    resources,
    license,
    totalBytes,
    requestCount: resources.length + 1,
  };
};

type GetPlaymeshExampleManifestOptions = {|
  header: PlaymeshExampleHeader,
  signal?: ?AbortSignal,
|};

export const getPlaymeshExampleManifest = async ({
  header,
  signal,
}: GetPlaymeshExampleManifestOptions): Promise<
  PlaymeshExampleManifestResult
> => {
  const [manifest, index] = await Promise.all([
    loadManifest({ signal }),
    loadPlaymeshExamplesIndex({ signal }),
  ]);
  const currentHeader = index.headers.find(candidate => candidate.id === header.id);
  if (!currentHeader) {
    throw new PlaymeshCatalogError('not_found', '示例已不在当前固定目录中。');
  }
  const exampleManifest = await buildRuntimeExampleManifest({
    header: currentHeader,
    index,
    manifest,
    signal,
  });
  return { manifest, exampleManifest };
};

type FetchPlaymeshExamplePreviewOptions = {|
  header: PlaymeshExampleHeader,
  signal?: ?AbortSignal,
|};

/**
 * Fetches an example thumbnail through the same App-owned, content-addressed
 * artifact path as projects and resources. Callers may turn the returned bytes
 * into a short-lived object URL, but must not persist the Blob in browser
 * storage.
 */
export const fetchPlaymeshExamplePreview = async ({
  header,
  signal,
}: FetchPlaymeshExamplePreviewOptions): Promise<?PlaymeshCatalogDownload> => {
  const [manifest, index] = await Promise.all([
    loadManifest({ signal }),
    loadPlaymeshExamplesIndex({ signal }),
  ]);
  const currentHeader = index.headers.find(
    candidate => candidate.id === header.id
  );
  if (!currentHeader) {
    throw new PlaymeshCatalogError('not_found', '示例已不在当前固定目录中。');
  }
  const files = validateExampleHeader({
    header: currentHeader,
    index,
    manifest,
  });
  const preview = currentHeader.preview;
  if (!preview) return null;
  const previewPath = ensureSafeRelativePath(preview.relativePath);
  const previewFile = files.get(previewPath);
  if (
    !previewFile ||
    previewFile.declaredBytes !== preview.declaredBytes ||
    previewFile.gitBlobOid !== preview.gitBlobOid ||
    previewFile.sha256 !== preview.sha256 ||
    previewFile.mediaType !== preview.mediaType ||
    !previewFile.mediaType.startsWith('image/')
  ) {
    throw new PlaymeshCatalogError(
      'invalid_example',
      '示例缩略图不在固定 Git tree 中。'
    );
  }
  const artifact = createExampleArtifact({
    header: currentHeader,
    source: index.source,
    file: previewFile,
    kind: 'example-preview',
  });
  return fetchCatalogArtifact({ artifact, limits: manifest.limits, signal });
};

export const fetchPlaymeshArtifact = ({
  artifact,
  limits,
  signal,
}: {|
  artifact: PlaymeshCatalogArtifact,
  limits: PlaymeshCatalogLimits,
  signal?: ?AbortSignal,
|}): Promise<PlaymeshCatalogDownload> =>
  fetchCatalogArtifact({ artifact, limits, signal });

export const resetPlaymeshCatalogForRetry = (
  feature?: ?CatalogFeature
): void => {
  rootManifestPromise = null;
  if (!feature || feature === 'extensions') extensionsIndexPromise = null;
  if (!feature || feature === 'examples') examplesIndexPromise = null;
};
