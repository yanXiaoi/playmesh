// @flow

const MAX_FIELD_CHANGES = 400;
const MAX_VALUE_PREVIEW_LENGTH = 240;

// The history payload is untrusted JSON and every access is guarded at runtime.
// Keep the Flow boundary intentionally broad while preserving those checks.
const hasOwn = (value: any, key: string): boolean =>
  // $FlowFixMe[method-unbinding] Object.prototype is the deliberate receiver.
  Object.prototype.hasOwnProperty.call(value, key);

const isRecord = (value: any): boolean =>
  !!value && typeof value === 'object' && !Array.isArray(value);

const asArray = (value: any): Array<any> =>
  Array.isArray(value) ? value : [];

const jsonEquals = (left: any, right: any): boolean =>
  JSON.stringify(left) === JSON.stringify(right);

const parseProject = (source: string): any => {
  const project = JSON.parse(source);
  if (!isRecord(project)) throw new Error('invalid_history_project_json');
  return project;
};

const namedItems = (value: any): Array<any> => {
  const output: Array<any> = [];
  for (const item of asArray(value)) {
    if (!isRecord(item) || typeof item.name !== 'string' || !item.name) {
      continue;
    }
    output.push(item);
  }
  return output;
};

const namedMap = (value: any): Map<string, any> =>
  new Map(namedItems(value).map(item => [item.name, item]));

const emptyChangeGroup = (): any => ({
  added: [],
  removed: [],
  modified: [],
});

const compareNamedRecords = (
  beforeRecords: Map<string, any>,
  afterRecords: Map<string, any>
): any => {
  const changes = emptyChangeGroup();
  const keys = Array.from(
    new Set([...beforeRecords.keys(), ...afterRecords.keys()])
  ).sort((left, right) => left.localeCompare(right));
  for (const key of keys) {
    const before = beforeRecords.get(key);
    const after = afterRecords.get(key);
    if (before === undefined) changes.added.push(after);
    else if (after === undefined) changes.removed.push(before);
    else if (!jsonEquals(before.value, after.value)) {
      changes.modified.push({
        ...after,
        beforeValue: before.value,
        afterValue: after.value,
      });
    }
  }
  return changes;
};

const collectScenes = (project: any): Map<string, any> => {
  const records: Map<string, any> = new Map();
  for (const layout of namedItems(project.layouts)) {
    records.set(layout.name, {
      key: layout.name,
      name: layout.name,
      value: layout,
    });
  }
  return records;
};

const collectObjects = (project: any): Map<string, any> => {
  const records: Map<string, any> = new Map();
  const addRecord = ({ locationType, locationName, name, value }: any): void => {
    const key = `${locationType}\u0000${locationName || ''}\u0000${name}`;
    records.set(key, { key, locationType, locationName, name, value });
  };

  for (const object of namedItems(project.objects)) {
    addRecord({
      locationType: 'global',
      locationName: null,
      name: object.name,
      value: { definition: object, instances: [] },
    });
  }

  for (const layout of namedItems(project.layouts)) {
    const definitions = namedMap(layout.objects);
    const instancesByName: Map<string, Array<any>> = new Map();
    for (const instance of namedItems(layout.instances)) {
      const instances = instancesByName.get(instance.name) || [];
      instances.push(instance);
      instancesByName.set(instance.name, instances);
    }
    const names = new Set([...definitions.keys(), ...instancesByName.keys()]);
    for (const name of names) {
      addRecord({
        locationType: 'scene',
        locationName: layout.name,
        name,
        value: {
          definition: definitions.get(name) || null,
          instances: instancesByName.get(name) || [],
        },
      });
    }
  }

  // 外部布局只有实例，没有场景内对象定义；仍以真实布局名和实例名展示其变化。
  for (const externalLayout of namedItems(project.externalLayouts)) {
    const instancesByName: Map<string, Array<any>> = new Map();
    for (const instance of namedItems(externalLayout.instances)) {
      const instances = instancesByName.get(instance.name) || [];
      instances.push(instance);
      instancesByName.set(instance.name, instances);
    }
    for (const [name, instances] of instancesByName) {
      addRecord({
        locationType: 'externalLayout',
        locationName: externalLayout.name,
        name,
        value: { definition: null, instances },
      });
    }
  }
  return records;
};

const collectResources = (project: any): Map<string, any> => {
  const records: Map<string, any> = new Map();
  const resources = isRecord(project.resources)
    ? project.resources.resources
    : null;
  for (const resource of namedItems(resources)) {
    records.set(resource.name, {
      key: resource.name,
      name: resource.name,
      value: resource,
    });
  }
  return records;
};

const valuePreview = (value: any): string => {
  if (value === undefined) return '';
  const serialized = JSON.stringify(value);
  if (serialized === undefined) return String(value);
  return serialized.length <= MAX_VALUE_PREVIEW_LENGTH
    ? serialized
    : `${serialized.slice(0, MAX_VALUE_PREVIEW_LENGTH - 1)}…`;
};

const namedArrayMap = (value: any): ?Map<string, any> => {
  if (!Array.isArray(value) || !value.length) return null;
  const map: Map<string, any> = new Map();
  for (const item of value) {
    if (!isRecord(item) || typeof item.name !== 'string' || !item.name) {
      return null;
    }
    if (map.has(item.name)) return null;
    map.set(item.name, item);
  }
  return map;
};

const fieldPath = (base: string, key: any): string =>
  /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(String(key))
    ? `${base}.${String(key)}`
    : `${base}[${JSON.stringify(String(key))}]`;

const namedFieldPath = (base: string, name: string): string =>
  `${base}[name=${JSON.stringify(name)}]`;

const collectFieldChanges = (beforeProject: any, afterProject: any): any => {
  const changes: Array<any> = [];
  let truncated = false;
  const append = (
    kind: string,
    path: string,
    before: any,
    after: any
  ): void => {
    if (changes.length >= MAX_FIELD_CHANGES) {
      truncated = true;
      return;
    }
    changes.push({
      kind,
      path,
      before: valuePreview(before),
      after: valuePreview(after),
    });
  };

  const visit = (before: any, after: any, path: string): void => {
    if (truncated || jsonEquals(before, after)) return;
    if (isRecord(before) && isRecord(after)) {
      const keys = Array.from(
        new Set([...Object.keys(before), ...Object.keys(after)])
      ).sort((left, right) => left.localeCompare(right));
      for (const key of keys) {
        if (!hasOwn(before, key)) {
          append('added', fieldPath(path, key), undefined, after[key]);
        } else if (!hasOwn(after, key)) {
          append('removed', fieldPath(path, key), before[key], undefined);
        } else {
          visit(before[key], after[key], fieldPath(path, key));
        }
        if (truncated) return;
      }
      return;
    }
    if (Array.isArray(before) && Array.isArray(after)) {
      const beforeNamed = namedArrayMap(before);
      const afterNamed = namedArrayMap(after);
      if (beforeNamed && afterNamed) {
        const beforeOrder = Array.from(beforeNamed.keys());
        const afterOrder = Array.from(afterNamed.keys());
        if (!jsonEquals(beforeOrder, afterOrder)) {
          append('modified', `${path}.[order]`, beforeOrder, afterOrder);
        }
        const names = Array.from(
          new Set([...beforeNamed.keys(), ...afterNamed.keys()])
        ).sort((left, right) => left.localeCompare(right));
        for (const name of names) {
          if (!beforeNamed.has(name)) {
            append(
              'added',
              namedFieldPath(path, name),
              undefined,
              afterNamed.get(name)
            );
          } else if (!afterNamed.has(name)) {
            append(
              'removed',
              namedFieldPath(path, name),
              beforeNamed.get(name),
              undefined
            );
          } else {
            visit(
              beforeNamed.get(name),
              afterNamed.get(name),
              namedFieldPath(path, name)
            );
          }
          if (truncated) return;
        }
        return;
      }
      const length = Math.max(before.length, after.length);
      for (let index = 0; index < length; index++) {
        const pathAtIndex = `${path}[${index}]`;
        if (index >= before.length) {
          append('added', pathAtIndex, undefined, after[index]);
        } else if (index >= after.length) {
          append('removed', pathAtIndex, before[index], undefined);
        } else {
          visit(before[index], after[index], pathAtIndex);
        }
        if (truncated) return;
      }
      return;
    }
    append('modified', path, before, after);
  };

  visit(beforeProject, afterProject, '$');
  return { changes, truncated };
};

export const buildPlaymeshHistoryDiffSummary = ({
  before,
  after,
}: {
  before: string,
  after: string,
}): any => {
  const beforeProject = parseProject(before);
  const afterProject = parseProject(after);
  return {
    scenes: compareNamedRecords(
      collectScenes(beforeProject),
      collectScenes(afterProject)
    ),
    objects: compareNamedRecords(
      collectObjects(beforeProject),
      collectObjects(afterProject)
    ),
    resources: compareNamedRecords(
      collectResources(beforeProject),
      collectResources(afterProject)
    ),
    fields: collectFieldChanges(beforeProject, afterProject),
  };
};
