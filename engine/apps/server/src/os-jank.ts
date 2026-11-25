import { lstatSync, readdirSync, realpathSync } from "node:fs";
import { productName } from "@t3tools/contracts/engineBrand";
import { UserError } from "effect/cli/CliError";
import * as HostProcess from "@t3tools/shared/HostProcess";
import {
  listLoginShellCandidates,
  mergePathEntries,
  readEnvironmentFromLoginShell,
  readPathFromLaunchctl,
  resolveWindowsEnvironment,
  setWindowsPath,
} from "@t3tools/shared/shell";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";
import * as NodeOS from "node:os";

function logPathHydrationWarning(message: string, error?: unknown): void {
  process.stderr.write(
    `[${productName} engine] ${message} ${error instanceof Error ? error.message : (error ?? "")}\n`,
  );
}

function hydratePosixPath(env: NodeJS.ProcessEnv, platform: NodeJS.Platform): void {
  let shellEnvironment: Partial<Record<string, string>> = {};
  for (const shell of listLoginShellCandidates(platform, env.SHELL)) {
    try {
      // mise's record of the PATH entries it added. It must travel with the
      // shell's PATH, or `mise x` can rebuild PATH behind a same-named wrapper
      // (`exec mise x claude -- claude`) that then re-runs itself forever.
      shellEnvironment = readEnvironmentFromLoginShell(shell, ["PATH", "__MISE_DIFF", "JAVA_HOME"]);
    } catch (error) {
      logPathHydrationWarning(`Failed to read PATH from login shell ${shell}.`, error);
    }

    if (shellEnvironment.PATH) break;
  }

  const shellPath = shellEnvironment.PATH;
  const launchctlPath = platform === "darwin" && !shellPath ? readPathFromLaunchctl() : undefined;
  const mergedPath = mergePathEntries(shellPath ?? launchctlPath, env.PATH, platform);
  if (mergedPath) {
    env.PATH = mergedPath;
  }
  if (shellPath && shellEnvironment.__MISE_DIFF) {
    env.__MISE_DIFF = shellEnvironment.__MISE_DIFF;
  }
  // Android SDK tools are Java programs. A keg-only JDK (Homebrew's openjdk)
  // is only reachable through the JAVA_HOME the shell profile sets.
  if (!env.JAVA_HOME && shellEnvironment.JAVA_HOME) {
    env.JAVA_HOME = shellEnvironment.JAVA_HOME;
  }
}

export function hydratePosixHome(
  env: NodeJS.ProcessEnv,
  resolveHomeDir = () => NodeOS.userInfo().homedir,
): void {
  if ((env.HOME?.trim() ?? "").length > 0) return;

  const homeDir = resolveHomeDir();
  if (homeDir.length > 0) {
    env.HOME = homeDir;
  }
}

export const fixPath = Effect.fn("fixPath")(function* (options?: {
  readonly shellEnvironmentPrepared?: boolean | undefined;
}): Effect.fn.Return<void, never, FileSystem.FileSystem | Path.Path> {
  const platform = yield* HostProcess.Platform;
  const env = yield* HostProcess.Environment;

  if (platform === "win32") {
    // Desktop already populated the child env; repeating PowerShell probes costs seconds.
    if (options?.shellEnvironmentPrepared === true) return;
    const repairedEnvironment = yield* resolveWindowsEnvironment(env).pipe(
      Effect.catchDefect((defect) =>
        Effect.sync(() => {
          logPathHydrationWarning("Failed to hydrate PATH from the user environment.", defect);
          return {} as Partial<NodeJS.ProcessEnv>;
        }),
      ),
    );
    for (const [key, value] of Object.entries(repairedEnvironment)) {
      if (value === undefined) continue;
      if (key === "PATH") {
        setWindowsPath(env, value);
      } else {
        env[key] = value;
      }
    }
    return;
  }

  if (platform !== "darwin" && platform !== "linux") return;

  yield* Effect.sync(() => hydratePosixHome(env)).pipe(
    Effect.catchDefect((defect) =>
      Effect.sync(() => {
        logPathHydrationWarning("Failed to hydrate HOME from the user account.", defect);
      }),
    ),
  );
  if (options?.shellEnvironmentPrepared === true) return;
  yield* Effect.sync(() => hydratePosixPath(env, platform)).pipe(
    Effect.catchDefect((defect) =>
      Effect.sync(() => {
        logPathHydrationWarning("Failed to hydrate PATH from the user environment.", defect);
      }),
    ),
  );
});

export const expandHomePath = Effect.fn(function* (input: string) {
  const { join } = yield* Path.Path;
  const home = yield* HostProcess.HomeDirectory;
  if (input === "~") {
    return home;
  }
  if (input.startsWith("~/") || input.startsWith("~\\")) {
    return join(home, input.slice(2));
  }
  return input;
});

// Resolve existing ancestors before creating anything, including a missing
// data directory reached through a symlink.
function canonicalStoragePath(path: string, paths: Path.Path): string {
  if (path.split(paths.sep).some((part) => part.toLowerCase() === ".t3")) {
    throw new Error("The legacy engine data directory is reserved.");
  }
  if (!lstatSync(path, { throwIfNoEntry: false })) {
    return paths.join(canonicalStoragePath(paths.dirname(path), paths), paths.basename(path));
  }
  const canonical = realpathSync(path);
  if (canonical.split(paths.sep).some((part) => part.toLowerCase() === ".t3")) {
    throw new Error("The legacy engine data directory is reserved.");
  }
  return canonical;
}

export const resolveBaseDir = Effect.fn(function* (raw: string | undefined) {
  const paths = yield* Path.Path;
  const home = yield* HostProcess.HomeDirectory;
  const proposed = raw?.trim()
    ? paths.resolve(yield* expandHomePath(raw.trim()))
    : paths.join(home, "Library", "Application Support", productName, "engine");
  return yield* Effect.try({
    try: () => {
      const baseDir = canonicalStoragePath(proposed, paths);
      // State and cache locations are owned by the engine. Reject linked
      // directories and top-level state files before opening the database.
      const ownedLocations = [
        "userdata", "userdata/secrets", "userdata/logs", "userdata/attachments",
        "userdata/themes", "caches", "worktrees", "runtime", "sdk",
      ];
      for (const location of ownedLocations) {
        const directory = paths.join(baseDir, location);
        if (lstatSync(directory, { throwIfNoEntry: false })?.isSymbolicLink()) {
          throw new Error("Engine storage directories must not be symlinks.");
        }
      }
      for (const location of ["userdata", "userdata/secrets"]) {
        const directory = paths.join(baseDir, location);
        if (!lstatSync(directory, { throwIfNoEntry: false })) continue;
        for (const entry of readdirSync(directory, { withFileTypes: true })) {
          if (entry.isSymbolicLink()) {
            throw new Error("Engine state files must not be symlinks.");
          }
        }
      }
      return baseDir;
    },
    catch: (error) => new UserError({
      cause: `Invalid engine data directory: ${error instanceof Error ? error.message : String(error)}`,
    }),
  });
});
