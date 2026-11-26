import { cpSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const output = resolve(process.argv[2]!);
const project = resolve(import.meta.dir, "../engine/apps/server");

// These packages locate native code or executable helpers by their real path.
const nativePackages = ["@ff-labs/fff-node", "ffi-rs", "node-pty"];
const copied = new Map<string, string>();

function findPackage(name: string, from: string): string | undefined {
  for (let dir = from; ; dir = dirname(dir)) {
    try {
      return realpathSync(join(dir, "node_modules", name, "package.json"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (dir === dirname(dir)) return undefined;
  }
}

function copyPackage(name: string, from: string, optional = false): void {
  const manifestPath = findPackage(name, from);
  if (manifestPath === undefined) {
    if (optional) return;
    throw new Error(`Cannot resolve ${name} from ${from}`);
  }
  const source = dirname(manifestPath);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const prior = copied.get(name);
  if (prior === manifestPath) return;
  if (prior !== undefined) throw new Error(`Conflicting versions of native dependency ${name}`);
  copied.set(name, manifestPath);

  const destination = join(output, "node_modules", name);
  mkdirSync(destination, { recursive: true });
  const metadata = (file: string) => /^(?:package\.json|LICENSE|NOTICE|COPYING)/i.test(file);
  const files = readdirSync(source).filter(metadata);
  if (name === "node-pty") {
    files.push("lib", "prebuilds/darwin-arm64");
  } else {
    files.push(...readdirSync(source).filter((file) => !metadata(file)));
  }
  for (const file of files) {
    const sourceFile = join(source, file);
    if (!statSync(sourceFile, { throwIfNoEntry: false })) continue;
    cpSync(sourceFile, join(destination, file), {
      recursive: true,
      dereference: true,
      filter: (path) =>
        !/^(?:node_modules|\.bun-tag-|__tests__|test$|tests$)/.test(basename(path)) &&
        !/\.(?:map|d\.[cm]?ts)$/.test(path),
    });
  }
  for (const dependency of Object.keys(manifest.dependencies ?? {})) {
    copyPackage(dependency, source);
  }
  for (const dependency of Object.keys(manifest.optionalDependencies ?? {})) {
    copyPackage(dependency, source, true);
  }
}

for (const name of nativePackages) copyPackage(name, project);
