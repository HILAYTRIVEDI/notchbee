require "fileutils"
require "json"
require "yaml"

stage, tag = ARGV
Dir.chdir(stage)
workspace = YAML.load_file("pnpm-workspace.yaml")
catalog = workspace.fetch("catalog")

# Drop upstream test fixtures and tooling before identifying runtime imports.
%w[apps/server packages].each do |root|
  Dir.glob("#{root}/**/{test,tests,testkit,scripts,fixtures,__snapshots__,__fixtures__,testUtils}", File::FNM_DOTMATCH).each do |path|
    FileUtils.rm_rf(path) if File.directory?(path)
  end
  Dir.glob("#{root}/**/*.{test,spec,fixture,testkit}.{ts,tsx,mjs,sh}").each { |path| FileUtils.rm_f(path) }
end

# Keep the helpers invoked by the native engine and provider subprocesses.
engine_cli = %w[claudeHistory.ts invocation.ts managedChatGptToken.ts]
Dir["apps/server/src/cli/*.ts"].each do |path|
  FileUtils.rm_f(path) unless engine_cli.include?(File.basename(path))
end
%w[binCli.ts cliCompileCache.ts entrypoint.ts outboundHttp.ts serviceLauncher.ts].each do |file|
  FileUtils.rm_f("apps/server/src/#{file}")
end

# The SSH device adapter uses the command helpers. The old desktop's tunnel
# installer is a different entry point that provisions an upstream T3 server.
removed_exports = {
  "@t3tools/shared" => ["./devHome"],
  "@t3tools/ssh" => ["./tunnel"]
}

manifests = (["apps/server/package.json"] + Dir["packages/*/package.json"]).to_h do |path|
  manifest = JSON.parse(File.read(path))
  [manifest.fetch("name"), [path, manifest]]
end
remaining = ["t3"]
selected = []
dependencies = []
until remaining.empty?
  name = remaining.shift
  next if selected.include?(name)

  path, manifest = manifests.fetch(name)
  dir = File.dirname(path)
  removed_exports.fetch(name, []).each do |entry|
    export = manifest.fetch("exports").delete(entry)
    FileUtils.rm_f(File.join(dir, export.fetch("import"))) if export
  end
  # Upstream declares some server runtime imports as dev dependencies.
  sources = Dir["#{dir}/{src,schema}/**/*.ts"].map { |file| File.read(file) }.join("\n")
  runtime_deps = manifest.fetch("dependencies", {}).merge(
    manifest.fetch("devDependencies", {}).select do |dependency, _|
      !dependency.end_with?("-testing", "/vitest") &&
        dependency != "@t3tools/web" &&
        sources.match?(/["']#{Regexp.escape(dependency)}(?:[\/"'])/)
    end
  )
  %w[playwright-core transcribe-cpp @napi-rs/keyring].each { |dependency| runtime_deps.delete(dependency) } if name == "t3"
  remaining.concat(runtime_deps.select { |_, version| version.start_with?("workspace:") }.keys)
  dependencies.concat(runtime_deps.keys)
  manifest.delete("devDependencies")
  manifest.delete("scripts")
  manifest["dependencies"] = runtime_deps.map do |dependency, version|
    [dependency, version == "catalog:" ? catalog.fetch(dependency) : version]
  end.to_h
  if name == "t3"
    manifest.delete("bin")
    manifest.delete("files")
    manifest.delete("engines")
    manifest["version"] = tag.delete_prefix("v") unless tag.empty?
  end
  File.write(path, JSON.pretty_generate(manifest) + "\n")
  selected << name
end

(manifests.keys - selected).each { |name| FileUtils.rm_rf(File.dirname(manifests.fetch(name).first)) }
Dir["packages/*/*"].each do |path|
  next if %w[package.json src schema].include?(File.basename(path)) || File.basename(path).start_with?("LICENSE")
  FileUtils.rm_rf(path)
end

patches = workspace.fetch("patchedDependencies").map do |dependency, patch|
  next unless %w[@ff-labs/fff-node @muse-code/sdk node-pty micromark-extension-gfm-table].include?(dependency.sub(/@[^@]+$/, ""))
  target = "dependency-patches/#{File.basename(patch)}"
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.cp(patch, target)
  [dependency, target]
end.compact.to_h
FileUtils.mkdir_p("dependency-patches")
FileUtils.rm_rf("patches")

# Keep the upstream Markdown pipeline and a single copy of Effect at runtime.
overrides = workspace.fetch("overrides").map do |dependency, version|
  next unless (dependencies + %w[micromark mdast-util-to-hast micromark-extension-gfm-table]).include?(dependency)
  [dependency, version == "catalog:" ? catalog.fetch(dependency) : version]
end.compact.to_h
File.write("package.json", JSON.pretty_generate({
  "name" => "notchpilot-engine-workspace",
  "private" => true,
  "workspaces" => ["apps/server", "packages/*"],
  "overrides" => overrides.sort.to_h,
  "patchedDependencies" => patches.sort.to_h
}) + "\n")
