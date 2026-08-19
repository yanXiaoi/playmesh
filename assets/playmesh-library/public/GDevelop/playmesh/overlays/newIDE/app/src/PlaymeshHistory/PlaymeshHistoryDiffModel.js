// @flow

export const HISTORY_DIFF_INITIAL_ENTRY_LIMIT = 80;
export const HISTORY_DIFF_ENTRY_PAGE_SIZE = 80;
export const HISTORY_DIFF_INITIAL_FIELD_LIMIT = 60;
export const HISTORY_DIFF_FIELD_PAGE_SIZE = 60;
export const HISTORY_RAW_JSON_PAGE_SIZE = 32 * 1024;

export type PlaymeshHistoryRawJsonPage = {|
  page: number,
  pageCount: number,
  start: number,
  end: number,
  totalCharacters: number,
  text: string,
|};

export const getPlaymeshHistoryRawJsonPage = (
  source: string,
  requestedPage: number,
  requestedPageSize: number = HISTORY_RAW_JSON_PAGE_SIZE
): PlaymeshHistoryRawJsonPage => {
  const pageSize =
    Number.isSafeInteger(requestedPageSize) && requestedPageSize > 0
      ? requestedPageSize
      : HISTORY_RAW_JSON_PAGE_SIZE;
  const pageCount = Math.max(1, Math.ceil(source.length / pageSize));
  const page = Math.max(
    0,
    Math.min(
      pageCount - 1,
      Number.isSafeInteger(requestedPage) ? requestedPage : 0
    )
  );
  const nominalStart = page * pageSize;
  const nominalEnd = Math.min(source.length, nominalStart + pageSize);
  const startsWithLowSurrogate =
    nominalStart > 0 &&
    nominalStart < source.length &&
    source.charCodeAt(nominalStart) >= 0xdc00 &&
    source.charCodeAt(nominalStart) <= 0xdfff;
  const endsBeforeLowSurrogate =
    nominalEnd < source.length &&
    source.charCodeAt(nominalEnd) >= 0xdc00 &&
    source.charCodeAt(nominalEnd) <= 0xdfff;
  const start = startsWithLowSurrogate ? nominalStart + 1 : nominalStart;
  const end = endsBeforeLowSurrogate ? nominalEnd + 1 : nominalEnd;
  return {
    page,
    pageCount,
    start,
    end,
    totalCharacters: source.length,
    text: source.slice(start, end),
  };
};

export type PlaymeshHistoryDiffCategory =
  | "scenes"
  | "objects"
  | "resources"
  | "project";
export type PlaymeshHistoryDiffStatus = "added" | "modified" | "removed";
export type PlaymeshHistoryDiffEntry = {
  id: string,
  category: PlaymeshHistoryDiffCategory,
  status: PlaymeshHistoryDiffStatus,
  name: string,
  path: string,
  locationType: ?string,
  locationName: ?string,
  resourceKind: ?string,
  resourceLogicalIdBefore: ?string,
  resourceLogicalIdAfter: ?string,
  fields: Array<any>,
};
export type PlaymeshHistoryDiffCount = {
  total: number,
  added: number,
  modified: number,
  removed: number,
};
export type PlaymeshHistoryDiffModel = {
  entries: Array<PlaymeshHistoryDiffEntry>,
  counts: {
    [category: PlaymeshHistoryDiffCategory]: PlaymeshHistoryDiffCount,
  },
  totalFields: number,
  fieldsTruncated: boolean,
};
export type PlaymeshHistoryDiffGroup = {
  category: PlaymeshHistoryDiffCategory,
  entries: Array<PlaymeshHistoryDiffEntry>,
};

const CATEGORY_ORDER: Array<PlaymeshHistoryDiffCategory> = [
  "scenes",
  "objects",
  "resources",
  "project",
];
const STATUS_ORDER: Array<PlaymeshHistoryDiffStatus> = [
  "added",
  "modified",
  "removed",
];

const asArray = (value: any): Array<any> =>
  Array.isArray(value) ? value : [];

const normalizedText = (value: any): string =>
  typeof value === "string" ? value.trim().toLocaleLowerCase() : "";

const namedToken = (name: any): string =>
  `[name=${JSON.stringify(name)}]`;

const entryPath = (
  category: PlaymeshHistoryDiffCategory,
  item: any
): string => {
  const name = typeof item.name === "string" ? item.name : "";
  const locationName =
    typeof item.locationName === "string" ? item.locationName : "";
  if (category === "scenes") return name;
  if (category === "resources") return name;
  if (item.locationType === "global") return `Global/${name}`;
  if (item.locationType === "externalLayout") {
    return `External layout/${locationName}/${name}`;
  }
  return `${locationName}/${name}`;
};

const createEntry = (
  category: PlaymeshHistoryDiffCategory,
  status: PlaymeshHistoryDiffStatus,
  item: any,
  index: number
): PlaymeshHistoryDiffEntry => {
  const name = typeof item.name === "string" ? item.name : "";
  const locationType =
    typeof item.locationType === "string" ? item.locationType : null;
  const locationName =
    typeof item.locationName === "string" ? item.locationName : null;
  const resourceKindCandidate =
    category === "resources" && item.value
      ? item.value.kind || item.value.type
      : null;
  const resourceLogicalId = (value: any): ?string =>
    value &&
    typeof value.file === "string" &&
    value.file.startsWith("playmesh-local-resource://")
      ? value.file
      : null;
  const beforeValue =
    status === "added" ? null : item.beforeValue || item.value;
  const afterValue =
    status === "removed" ? null : item.afterValue || item.value;
  return {
    id: `${category}:${status}:${item.key || name || index}`,
    category,
    status,
    name,
    path: entryPath(category, item),
    locationType,
    locationName,
    resourceKind:
      typeof resourceKindCandidate === "string"
        ? resourceKindCandidate
        : null,
    resourceLogicalIdBefore:
      category === "resources" ? resourceLogicalId(beforeValue) : null,
    resourceLogicalIdAfter:
      category === "resources" ? resourceLogicalId(afterValue) : null,
    fields: [],
  };
};

const findResourceEntry = (
  entries: Array<PlaymeshHistoryDiffEntry>,
  path: string
): ?PlaymeshHistoryDiffEntry => {
  const prefix = "$.resources.resources";
  if (!path.startsWith(prefix)) return null;
  return entries.find(
    entry =>
      entry.category === "resources" &&
      path.startsWith(`${prefix}${namedToken(entry.name)}`)
  );
};

const findObjectEntry = (
  entries: Array<PlaymeshHistoryDiffEntry>,
  path: string
): ?PlaymeshHistoryDiffEntry =>
  entries.find(entry => {
    if (entry.category !== "objects") return false;
    const object = namedToken(entry.name);
    if (entry.locationType === "global") {
      return path.startsWith(`$.objects${object}`);
    }
    if (entry.locationType === "externalLayout") {
      const layout = namedToken(entry.locationName || "");
      return path.startsWith(`$.externalLayouts${layout}.instances${object}`);
    }
    const scene = namedToken(entry.locationName || "");
    return (
      path.startsWith(`$.layouts${scene}.objects${object}`) ||
      path.startsWith(`$.layouts${scene}.instances${object}`)
    );
  }) || null;

const findSceneEntry = (
  entries: Array<PlaymeshHistoryDiffEntry>,
  path: string
): ?PlaymeshHistoryDiffEntry =>
  entries.find(
    entry =>
      entry.category === "scenes" &&
      path.startsWith(`$.layouts${namedToken(entry.name)}`)
  ) || null;

const compareEntries = (
  left: PlaymeshHistoryDiffEntry,
  right: PlaymeshHistoryDiffEntry
): number => {
  const categoryOrder =
    CATEGORY_ORDER.indexOf(left.category) -
    CATEGORY_ORDER.indexOf(right.category);
  if (categoryOrder) return categoryOrder;
  const statusOrder =
    STATUS_ORDER.indexOf(left.status) - STATUS_ORDER.indexOf(right.status);
  if (statusOrder) return statusOrder;
  return left.path.localeCompare(right.path);
};

const resourceKindFromMime = (mime: any): ?string => {
  if (typeof mime !== "string") return null;
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  if (mime.startsWith("font/")) return "font";
  if (mime.startsWith("model/")) return "model";
  return null;
};

const appendResourceEvidenceOnlyEntries = (
  entries: Array<PlaymeshHistoryDiffEntry>,
  resourceEvidence: any
): void => {
  const beforeResources = asArray(resourceEvidence?.before).filter(
    resource =>
      resource &&
      typeof resource.logicalId === "string" &&
      typeof resource.contentHash === "string"
  );
  const afterResources = asArray(resourceEvidence?.after).filter(
    resource =>
      resource &&
      typeof resource.logicalId === "string" &&
      typeof resource.contentHash === "string"
  );
  const beforeByLogicalId: Map<string, any> = new Map(
    beforeResources.map(resource => [resource.logicalId, resource])
  );
  const afterByLogicalId: Map<string, any> = new Map(
    afterResources.map(resource => [resource.logicalId, resource])
  );
  const representedBefore = new Set(
    entries
      .map(entry => entry.resourceLogicalIdBefore)
      .filter(Boolean)
  );
  const representedAfter = new Set(
    entries
      .map(entry => entry.resourceLogicalIdAfter)
      .filter(Boolean)
  );
  const logicalIds = Array.from(
    new Set([...beforeByLogicalId.keys(), ...afterByLogicalId.keys()])
  ).sort((left, right) => left.localeCompare(right));
  for (const logicalId of logicalIds) {
    const before = beforeByLogicalId.get(logicalId);
    const after = afterByLogicalId.get(logicalId);
    if (
      before &&
      after &&
      before.contentHash === after.contentHash &&
      before.mime === after.mime &&
      before.size === after.size
    ) {
      continue;
    }
    if (representedBefore.has(logicalId) || representedAfter.has(logicalId)) {
      continue;
    }
    const status: PlaymeshHistoryDiffStatus = !before
      ? "added"
      : !after
      ? "removed"
      : "modified";
    const evidence = after || before;
    if (!evidence) {
      continue;
    }
    const name =
      typeof evidence.name === "string" && evidence.name
        ? evidence.name
        : logicalId;
    entries.push({
      id: `resources:${status}:evidence:${logicalId}`,
      category: "resources",
      status,
      name,
      path: name,
      locationType: null,
      locationName: null,
      resourceKind: resourceKindFromMime(evidence.mime),
      resourceLogicalIdBefore: before ? logicalId : null,
      resourceLogicalIdAfter: after ? logicalId : null,
      fields: []
    });
  }
};

export const buildPlaymeshHistoryDiffModel = (
  semanticDiff: any,
  resourceEvidence: ?any = null
): PlaymeshHistoryDiffModel => {
  const entries: Array<PlaymeshHistoryDiffEntry> = [];
  const trackedCategories: Array<PlaymeshHistoryDiffCategory> = [
    "scenes",
    "objects",
    "resources",
  ];
  for (const category of trackedCategories) {
    const group = semanticDiff[category] || {};
    for (const status of STATUS_ORDER) {
      asArray(group[status]).forEach((item, index) => {
        entries.push(createEntry(category, status, item, index));
      });
    }
  }
  appendResourceEvidenceOnlyEntries(entries, resourceEvidence);

  const unassignedFields: Array<any> = [];
  for (const field of asArray(semanticDiff.fields?.changes)) {
    const owner =
      findResourceEntry(entries, field.path) ||
      findObjectEntry(entries, field.path) ||
      findSceneEntry(entries, field.path);
    if (owner) owner.fields.push(field);
    else unassignedFields.push(field);
  }

  if (unassignedFields.length) {
    entries.push({
      id: "project:modified:project.gdevelop.json",
      category: "project",
      status: "modified",
      name: "project.gdevelop.json",
      path: "project.gdevelop.json",
      locationType: null,
      locationName: null,
      resourceKind: null,
      resourceLogicalIdBefore: null,
      resourceLogicalIdAfter: null,
      fields: unassignedFields
    });
  }

  entries.sort(compareEntries);
  const counts: {
    [category: PlaymeshHistoryDiffCategory]: PlaymeshHistoryDiffCount,
  } = {};
  for (const category of CATEGORY_ORDER) {
    const categoryEntries = entries.filter(
      entry => entry.category === category
    );
    counts[category] = {
      total: categoryEntries.length,
      added: categoryEntries.filter(entry => entry.status === "added").length,
      modified: categoryEntries.filter(entry => entry.status === "modified")
        .length,
      removed: categoryEntries.filter(entry => entry.status === "removed")
        .length
    };
  }
  return {
    entries,
    counts,
    totalFields: entries.reduce(
      (total, entry) => total + entry.fields.length,
      0
    ),
    fieldsTruncated: !!semanticDiff.fields?.truncated
  };
};

export const filterPlaymeshHistoryDiffEntries = (
  model: PlaymeshHistoryDiffModel,
  {
    query = "",
    category = "all",
    status = "all",
  }: {
    query?: string,
    category?: "all" | PlaymeshHistoryDiffCategory,
    status?: "all" | PlaymeshHistoryDiffStatus,
  } = {}
): Array<PlaymeshHistoryDiffEntry> => {
  const search = normalizedText(query);
  return model.entries.filter(entry => {
    if (category !== "all" && entry.category !== category) return false;
    if (status !== "all" && entry.status !== status) return false;
    if (!search) return true;
    return (
      normalizedText(entry.path).includes(search) ||
      normalizedText(entry.resourceKind).includes(search) ||
      entry.fields.some(field => normalizedText(field.path).includes(search))
    );
  });
};

export const groupPlaymeshHistoryDiffEntries = (
  entries: Array<PlaymeshHistoryDiffEntry>
): Array<PlaymeshHistoryDiffGroup> =>
  CATEGORY_ORDER.map(category => ({
    category,
    entries: entries.filter(entry => entry.category === category)
  })).filter(group => group.entries.length);
