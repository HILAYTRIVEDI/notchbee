import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const [metafile, nativeDirectory] = process.argv.slice(2);
const bundled = JSON.parse(readFileSync(metafile!, "utf8"));
const roots = new Map<string, boolean>();

function packageRoot(input: string): string {
  for (let directory = dirname(resolve(input)); directory !== dirname(directory); directory = dirname(directory)) {
    if (/\/node_modules\/(?:@[^/]+\/)?[^/]+$/.test(directory) &&
        existsSync(join(directory, "package.json"))) {
      return directory;
    }
  }
  throw new Error(`Cannot identify the bundled npm package for ${input}`);
}

for (const output of Object.values(bundled.outputs) as { inputs: Record<string, { bytesInOutput: number }> }[]) {
  for (const [input, contribution] of Object.entries(output.inputs)) {
    if (!/(^|\/)node_modules\//.test(input) || contribution.bytesInOutput === 0) continue;
    roots.set(packageRoot(input), false);
  }
}

const nativeModules = join(nativeDirectory!, "node_modules");
for (const name of readdirSync(nativeModules)) {
  const directory = join(nativeModules, name);
  if (name.startsWith("@")) {
    for (const child of readdirSync(directory)) roots.set(join(directory, child), true);
  } else {
    roots.set(directory, true);
  }
}

const engine = resolve(import.meta.dir, "../engine");
console.log(readFileSync(join(engine, "THIRD_PARTY_NOTICES"), "utf8").trimEnd());
console.log("\n--- T3 Code LICENSE ---\n");
console.log(readFileSync(join(engine, "LICENSE"), "utf8").trimEnd());

console.log("\n--- Packages in the compiled engine or its staged native archive ---");
const notices = new Map<string, { metadata: string; files: Map<string, string> }>();
for (const [root, staged] of roots) {
  const { name, version, license, repository } = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  if (!name || !version) throw new Error(`Missing package name or version in ${root}`);
  if (/^(?:@anthropic-ai\/claude-agent-sdk|@cursor\/sdk)(?:-|$)/.test(name)) {
    throw new Error(`Proprietary SDK payload in engine distribution: ${name}@${version}`);
  }
  const key = `${name}@${version}`;
  const metadata = [license, typeof repository === "string" ? repository : repository?.url].filter(Boolean);
  const notice = notices.get(key) ?? { metadata: metadata.join("\n"), files: new Map<string, string>() };
  for (const file of readdirSync(root, { recursive: staged, withFileTypes: true })) {
    if (!file.isFile() || !/^(licen[cs]e|notice|copying|unlicense)([._-]|$)/i.test(file.name)) continue;
    const content = readFileSync(join(file.parentPath, file.name), "utf8").trimEnd();
    notice.files.set(content, basename(file.name));
  }
  notices.set(key, notice);
}

for (const [dependency, notice] of [...notices].sort(([left], [right]) => left.localeCompare(right))) {
  console.log(`\n--- ${dependency} ---\n${notice.metadata}`);
  for (const [content, name] of notice.files) console.log(`\n${name}\n${content}\n`);
  if (!notice.files.size) console.log("No license file in the npm package root or staged files. See supplemental notices.");
}
