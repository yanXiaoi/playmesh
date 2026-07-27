import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const serverRoot = resolve(toolDir, "..");
const sourceRoot = resolve(serverRoot, "..", "assets", "playmesh-localization");
const targetRoot = join(serverRoot, "internal", "localization", "assets");
const manifest = JSON.parse(await readFile(join(sourceRoot, "manifest.json"), "utf8"));

await mkdir(targetRoot, { recursive: true });
const generatedLocales = [];
for (const locale of manifest.locales.filter((item) => item.enabled)) {
  const content = await readFile(join(sourceRoot, locale.bundles.goServer), "utf8");
  JSON.parse(content);
  const targetName = `${locale.id}.json`;
  await writeFile(join(targetRoot, targetName), content.endsWith("\n") ? content : `${content}\n`);
  generatedLocales.push({
    id: locale.id,
    label: locale.label,
    enabled: true,
    fallback: locale.fallback,
    bundles: { goServer: targetName }
  });
}
const generatedManifest = {
  manifestVersion: manifest.manifestVersion,
  defaultLocale: manifest.defaultLocale,
  ui: manifest.ui,
  locales: generatedLocales
};
await writeFile(
  join(targetRoot, "manifest.json"),
  `${JSON.stringify(generatedManifest, null, 2)}\n`
);
