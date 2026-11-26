import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import {
  type ProviderSdkDriver,
  providerSdkDirectory,
  providerSdkInstalled,
  providerSdkInstallPath,
  providerSdkMetadata,
} from "@t3tools/shared/providerSdk";

type Pin = readonly [packageName: string, version: string, integrity: string];

// Runtime tarballs from the frozen engine lock. Claude Code itself is a separate executable
// installed by the user. The Claude JS entry is self-contained when given that executable.
const pins: Record<ProviderSdkDriver, readonly Pin[]> = {
  claudeAgent: [
    ["@anthropic-ai/claude-agent-sdk","0.3.330","sha512-7om9Xus6tfkeCUCfzg6ilJuN6Z7okkEvJ0mx+ukXa/Id5U/6BGtPkOYni+3ebedwa3b9SVF7A05+ln+/9EoU/w=="],
  ],
  cursor: [
    ["@cursor/sdk","1.2.0","sha512-Nqm2U0zTWrYEDCv3Rdwsfa1gYZWsg+JnY+I2F8BwWSAr3FNo0TZWwyHWoWngZgriF1w02fJ4gjJWaul9zysvgQ=="],
    ["@cursor/sdk-darwin-arm64","1.2.0","sha512-UkZ/RdxKCpOQ85nRgzSq+g0h+gIw36/lCEvQvomhs5EkSFZW3OwbeEzkAU3UYglZ7t3RNHj3mc5C5cdDtHguvw=="],
    ["@bufbuild/protobuf","1.10.0","sha512-QDdVFLoN93Zjg36NoQPZfsVH9tZew7wKDKyV5qRdj8ntT4wQCOradQjRaTdwMhWUYsgKsvCINKKm87FdEk96Ag=="],
    ["@connectrpc/connect","1.7.0","sha512-iNKdJRi69YP3mq6AePRT8F/HrxWCewrhxnLMNm0vpqXAR8biwzRtO6Hjx80C6UvtKJ5sFmffQT7I4Baecz389w=="],
    ["@connectrpc/connect-web","1.7.0","sha512-qyP0YOnUPRWwCc/VfsoydMJvkb7EyUPr2q9sHgBuJzbADjiqck1gKH5V5ZPzPhTLBvmz5UvG+wiZ5sMRQHU1MQ=="],
    ["@statsig/js-client","3.31.0","sha512-LFa5E0LjT6sTfZv3sNGoyRLSZ1078+agdgOA+Vm1ecjG+KbSOfBLTW7hMwimrJ29slRwbYDzbtKaPJo/R37N2g=="],
    ["@statsig/client-core","3.31.0","sha512-SuxQD6TmVszPG7FoMKwTk/uyBuVFk7XnxI3T/E0uyb7PL7GNjONtfsoh+NqBBVUJVse0CUeSFfgJPoZy1ZOslQ=="],
    ["zod","4.6.7","sha512-g8W2D2kU6a8untc053fX1uVBKzM7yqAxW/3zwk83+6RyF2+SKOuV+c0wBDhUwzV1PaGapmZH+rmcUzPf+3CGwg=="],
  ],
};
const pending = new Map<ProviderSdkDriver, Promise<void>>();
const maxPackageBytes = 128 * 1024 * 1024;

async function unpack(pin: Pin, stage: string, signal: AbortSignal): Promise<void> {
  const [name, version, integrity] = pin;
  const slug = name.split("/").at(-1)!;
  const url = `https://registry.npmjs.org/${name}/-/${slug}-${version}.tgz`;
  const archive = join(stage, slug + ".tgz");
  const destination = join(stage, "node_modules", name);
  let response: Response;
  try {
    response = await fetch(url, { redirect: "error", signal });
  } catch {
    throw new Error("Could not reach registry.npmjs.org. Check your internet connection and retry.");
  }
  if (!response.ok || !response.body) {
    throw new Error(`registry.npmjs.org returned HTTP ${response.status} for ${name}@${version}.`);
  }
  let length = 0;
  try {
    await Bun.write(archive, response.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        length += chunk.length;
        if (length > maxPackageBytes) throw new Error("Package exceeds the download limit.");
        controller.enqueue(chunk);
      },
    })));
  } catch {
    throw new Error(`Could not finish downloading ${name}@${version}. Check your connection and disk space, then retry.`);
  }
  const sha512 = createHash("sha512");
  for await (const chunk of createReadStream(archive)) sha512.update(chunk);
  if (`sha512-${sha512.digest("base64")}` !== integrity) {
    throw new Error(`Integrity verification failed for ${name}@${version}.`);
  }
  await mkdir(destination, { recursive: true, mode: 0o700 });
  // Extract the authenticated tarball directly. No package manager or lifecycle scripts run.
  const tar = Bun.spawn(["/usr/bin/tar", "-xzf", archive, "--strip-components", "1", "-C", destination], {
    stdout: "ignore",
    stderr: "ignore",
    signal,
  });
  if (await tar.exited !== 0) throw new Error(`Could not extract ${name}@${version}.`);
  await rm(archive);
  const manifest = JSON.parse(await readFile(join(destination, "package.json"), "utf8"));
  if (manifest.name !== name || manifest.version !== version) {
    throw new Error(`Unexpected package metadata for ${name}@${version}.`);
  }
}

async function install(driver: ProviderSdkDriver): Promise<void> {
  if (providerSdkInstalled(driver)) return;
  const root = join(providerSdkDirectory(), "sdk");
  await mkdir(root, { recursive: true, mode: 0o700 });
  const stat = await lstat(root);
  if (!stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) {
    throw new Error("Provider SDK storage must be an owner-only directory.");
  }

  const stage = await mkdtemp(join(root, ".install-"));
  try {
    const signal = AbortSignal.timeout(90_000);
    const results = await Promise.allSettled(pins[driver].map((pin) => unpack(pin, stage, signal)));
    for (const result of results) {
      if (result.status === "rejected") throw result.reason;
    }
    await writeFile(join(stage, "installed.json"), JSON.stringify(providerSdkMetadata[driver]), { mode: 0o600 });
    try {
      await rename(stage, providerSdkInstallPath(driver));
    } catch (error) {
      if (!providerSdkInstalled(driver)) throw error;
    }
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

export function installProviderSdk(driver: ProviderSdkDriver, version: string): Promise<void> {
  if (version !== providerSdkMetadata[driver].version) {
    return Promise.reject(new Error("The SDK version changed. Review the updated provider setup and retry."));
  }
  const current = pending.get(driver);
  if (current) return current;
  const task = install(driver).finally(() => pending.delete(driver));
  pending.set(driver, task);
  return task;
}
