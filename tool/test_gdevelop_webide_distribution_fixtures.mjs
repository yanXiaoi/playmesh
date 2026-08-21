import assert from "node:assert/strict";
import fs from "node:fs";

const fixtureUrl = new URL(
  "../test/fixtures/gdevelop_web_ide_distribution_cases.json",
  import.meta.url,
);
const fixture = JSON.parse(fs.readFileSync(fixtureUrl, "utf8"));
const catalogAsset = new URL(
  "../assets/app/App.json",
  import.meta.url,
);
const legacyDevelopmentAsset = new URL(
  "../assets/app/GdevelopWebIDE.json",
  import.meta.url,
);
const pubspec = fs.readFileSync(new URL("../pubspec.yaml", import.meta.url), "utf8");
const releaseVerifier = fs.readFileSync(
  new URL("./verify_release_assets.ps1", import.meta.url),
  "utf8",
);

verifyCases(fixture.endpointCases, parseEndpoints);
verifyCases(fixture.manifestCases, parseManifest);
parseCatalogEndpoints(fs.readFileSync(catalogAsset, "utf8"), "gdevelop");
assert.equal(fs.existsSync(legacyDevelopmentAsset), false);
assert.equal(
  (pubspec.match(/^\s*- assets\/app\/App\.json\s*$/gm) ?? []).length,
  1,
);
assert.doesNotMatch(pubspec, /assets\/app\/GdevelopWebIDE\.json/);
assert.match(
  releaseVerifier,
  /\$relativeFiles\.Add\(\$appResourceSourceCatalogRelativePath\)/,
);
assert.doesNotMatch(
  releaseVerifier,
  /\$relativeFiles\.Add\(\$legacyGdevelopWebIdeSourcesRelativePath\)/,
);
assert.match(
  releaseVerifier,
  /Legacy GDevelop Web IDE source asset must be removed/,
);
assert.match(
  releaseVerifier,
  /Packaged release contains legacy GDevelop Web IDE source asset/,
);
assert.doesNotMatch(
  releaseVerifier,
  /Production release requires at least one GDevelop Web IDE config source/,
);

const catalog = [
  {
    name: "A",
    app: "https://example.com/app-a.json",
    gdevelop: "https://example.com/gdevelop-a.json",
    future: { schema: 1 },
  },
  { name: "B", app: "https://example.com/app-b.json" },
  { name: "C", gdevelop: "https://example.com/gdevelop-c.json" },
  42,
];
assert.deepEqual(
  parseCatalogEndpoints(JSON.stringify(catalog), "app").map(({ name }) => name),
  ["A", "B"],
);
assert.deepEqual(
  parseCatalogEndpoints(JSON.stringify(catalog), "gdevelop").map(
    ({ name }) => name,
  ),
  ["A", "C"],
);
assert.throws(
  () => parseCatalogEndpoints(JSON.stringify(catalog), "future"),
  /endpoint URL/,
);

const tooMany = Array.from({ length: 17 }, (_, index) => ({
  name: `Endpoint ${index}`,
  url: `https://example.com/file-${index}.json`,
}));
assert.throws(() => parseEndpoints(JSON.stringify(tooMany)), /endpoint count/);
assert.doesNotThrow(() =>
  parseCatalogEndpoints(
    JSON.stringify([
      ...tooMany,
      { name: "GDevelop", gdevelop: "https://example.com/gdevelop.json" },
    ]),
    "gdevelop",
  ),
);
assert.throws(
  () =>
    parseCatalogEndpoints(
      JSON.stringify(
        tooMany.map(({ name, url }) => ({ name, gdevelop: url })),
      ),
      "gdevelop",
    ),
  /endpoint count/,
);
assert.throws(
  () =>
    parseManifest(
      JSON.stringify({
        version: "release-1",
        sha256: "1".repeat(64),
        size: 123,
        downloads: tooMany,
      }),
    ),
  /endpoint count/,
);

console.log("GDevelop Web IDE two-level distribution fixture parity passed");

function verifyCases(cases, parser) {
  for (const testCase of cases) {
    const source = Object.hasOwn(testCase, "source")
      ? testCase.source
      : JSON.stringify(testCase.value);
    let error = null;
    try {
      parser(source);
    } catch (caught) {
      error = caught;
    }
    assert.equal(
      error === null,
      testCase.valid,
      `${testCase.name}: ${error?.message ?? "unexpected success"}`,
    );
  }
}

function parseManifest(source) {
  const root = strictObject(JSON.parse(source), [
    "version",
    "sha256",
    "size",
    "downloads",
  ]);
  if (
    typeof root.version !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(root.version)
  ) {
    throw new TypeError("invalid version");
  }
  if (
    typeof root.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/.test(root.sha256)
  ) {
    throw new TypeError("invalid sha256");
  }
  if (
    !Number.isSafeInteger(root.size) ||
    root.size <= 0
  ) {
    throw new TypeError("invalid size");
  }
  const downloads = parseEndpoints(JSON.stringify(root.downloads), false);
  return {
    version: root.version,
    sha256: root.sha256,
    size: root.size,
    downloads,
  };
}

function parseCatalogEndpoints(source, resource) {
  const catalog = JSON.parse(source);
  if (!Array.isArray(catalog)) throw new TypeError("expected catalog array");
  const projected = [];
  for (const channel of catalog) {
    if (
      channel === null ||
      Array.isArray(channel) ||
      typeof channel !== "object" ||
      !Object.hasOwn(channel, resource)
    ) {
      continue;
    }
    projected.push({ name: channel.name, url: channel[resource] });
  }
  return parseEndpoints(JSON.stringify(projected));
}

function parseEndpoints(source, allowEmpty = true) {
  const endpoints = JSON.parse(source);
  if (!Array.isArray(endpoints)) throw new TypeError("expected endpoint array");
  if (!allowEmpty && endpoints.length === 0) {
    throw new TypeError("endpoint array is empty");
  }
  if (endpoints.length > 16) throw new TypeError("endpoint count exceeded");
  const names = new Set();
  const urls = new Set();
  return endpoints.map((rawEndpoint) => {
    const endpoint = strictObject(rawEndpoint, ["name", "url"]);
    const { name, url } = endpoint;
    if (
      typeof name !== "string" ||
      name.length === 0 ||
      name.trim() !== name ||
      name.length > 80 ||
      /[\u0000-\u001f\u007f]/.test(name) ||
      names.has(name.toLowerCase())
    ) {
      throw new TypeError("invalid endpoint name");
    }
    names.add(name.toLowerCase());
    if (typeof url !== "string" || url.length === 0 || url.trim() !== url) {
      throw new TypeError("invalid endpoint URL");
    }
    if (urls.has(url)) throw new TypeError("duplicate endpoint URL");
    urls.add(url);
    return { name, url };
  });
}

function strictObject(value, keys) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new TypeError("expected object");
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  assert.deepEqual(actual, expected);
  return value;
}
