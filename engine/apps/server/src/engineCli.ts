import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { DesktopBackendBootstrap } from "@t3tools/contracts";
import { engineEnv, engineName, productName } from "@t3tools/contracts/engineBrand";
import * as Config from "effect/Config";
import { configureProviderSdkDirectory } from "@t3tools/shared/providerSdk";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Command, Flag, GlobalFlag } from "effect/cli";
import { UserError } from "effect/cli/CliError";

import packageJson from "../package.json" with { type: "json" };
import { readBootstrapEnvelope } from "./bootstrap.ts";
import { claudeHistoryCommand } from "./cli/claudeHistory.ts";
import * as ServerConfig from "./config.ts";
import { awaitLauncherLoss } from "./launcherWatch.ts";
import { resolveBaseDir } from "./os-jank.ts";
import * as DatabaseMaintenance from "./persistence/DatabaseMaintenance.ts";

const loopback = "127.0.0.1";
const Port = Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 65535 }));
const BootstrapFd = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));
const EngineBootstrap = DesktopBackendBootstrap.mapFields((fields) => ({
  ...fields,
  port: Port,
}));

const flags = {
  baseDir: Flag.String("base-dir").pipe(
    Flag.withDescription(`Data directory. Defaults to ~/Library/Application Support/${productName}/engine.`),
    Flag.optional,
  ),
  port: Flag.Int("port").pipe(
    Flag.withSchema(Port),
    Flag.withDescription("Loopback HTTP/WebSocket port. Use 0 (the default) for an OS-assigned port."),
    Flag.optional,
  ),
  bootstrapFd: Flag.Int("bootstrap-fd").pipe(
    Flag.withSchema(BootstrapFd),
    Flag.withDescription("Read the native auth bootstrap envelope from an inherited descriptor."),
    Flag.optional,
  ),
  launcherPid: Flag.Int("launcher-pid").pipe(
    Flag.withSchema(Schema.Int.check(Schema.isGreaterThanOrEqualTo(2))),
    Flag.withDescription("Expected parent process ID when launched by the app."),
    Flag.optional,
  ),
};

const requiredBootstrap = (fd: number) =>
  readBootstrapEnvelope(EngineBootstrap, fd).pipe(
    // Schema errors may contain the original envelope. Keep credentials out of CLI logs.
    Effect.option,
    Effect.flatMap((read) => {
      const envelope = Option.flatten(read);
      return Option.isSome(envelope) && envelope.value.desktopBootstrapToken.trim().length >= 32
        ? Effect.succeed(envelope.value)
        : Effect.fail(new UserError({
            cause: "Invalid native bootstrap envelope.",
            userMessage: `Invalid or missing bootstrap envelope on fd ${fd}.`,
          }));
    }),
  );

function ignoreClosedLauncherPipe(error: NodeJS.ErrnoException): void {
  if (error.code !== "EPIPE" && error.code !== "ERR_STREAM_DESTROYED") throw error;
}

const launch = Effect.fn("engine.launch")(function* (input: {
  readonly baseDir: Option.Option<string>;
  readonly port: Option.Option<number>;
  readonly bootstrapFd: Option.Option<number>;
  readonly launcherPid: Option.Option<number>;
}) {
  const launcherPid = Option.getOrUndefined(input.launcherPid);
  if (launcherPid !== undefined && launcherPid !== process.ppid) {
    return yield* new UserError({ cause: "The engine launcher has exited." });
  }
  const env = yield* Config.all({
    baseDir: Config.String(engineEnv("HOME")).pipe(Config.option),
    port: Config.schema(Port, engineEnv("PORT")).pipe(Config.option),
    fd: Config.schema(BootstrapFd, engineEnv("BOOTSTRAP_FD")).pipe(Config.option),
    logLevel: Config.LogLevel(engineEnv("LOG_LEVEL")).pipe(Config.withDefault("Info")),
  });
  const fd = Option.getOrUndefined(Option.orElse(input.bootstrapFd, () => env.fd));
  if (fd === undefined) {
    return yield* new UserError({ cause: "An inherited --bootstrap-fd is required to launch the engine." });
  }
  const bootstrap = yield* requiredBootstrap(fd);
  const port = Option.getOrElse(Option.orElse(input.port, () => env.port), () => bootstrap.port);
  const baseDir = yield* resolveBaseDir(
    Option.getOrElse(Option.orElse(input.baseDir, () => env.baseDir), () => bootstrap.t3Home),
  );
  process.umask(0o077);
  configureProviderSdkDirectory(baseDir);
  const derivedPaths = yield* ServerConfig.deriveServerPaths(baseDir, undefined);
  yield* ServerConfig.ensureServerDirectories(derivedPaths);
  const cliLogLevel = yield* GlobalFlag.LogLevel;
  const config = ServerConfig.make({
    ...derivedPaths,
    logLevel: Option.getOrElse(cliLogLevel, () => env.logLevel),
    mode: "desktop",
    port,
    host: loopback,
    cwd: process.cwd(),
    baseDir,
    staticDir: undefined,
    devUrl: undefined,
    devAllowedOrigins: [],
    noBrowser: true,
    startupPresentation: "headless",
    desktopBootstrapToken: bootstrap.desktopBootstrapToken,
    ...(bootstrap.desktopBootstrapSecret === undefined ? {} : { desktopBootstrapSecret: bootstrap.desktopBootstrapSecret }),
    shellEnvironmentPrepared: bootstrap.shellEnvironmentPrepared,
    desktopTelemetryFd: undefined,
    desktopTelemetryControlFd: undefined,
    desktopBrowserFd: undefined,
    desktopBrowserControlFd: undefined,
    autoBootstrapProjectFromCwd: false,
    logWebSocketEvents: false,
    tailscaleServeEnabled: false,
    tailscaleServePort: 443,
  });

  process.stdout.on("error", ignoreClosedLauncherPipe);
  process.stderr.on("error", ignoreClosedLauncherPipe);
  const { runServer } = yield* Effect.promise(() => import("./server.ts"));
  yield* Effect.raceFirst(
    runServer.pipe(
      Effect.provideService(ServerConfig.ServerConfig, config),
      Effect.ensuring(
        DatabaseMaintenance.runRequestedReclaim(config.dbPath).pipe(
          Effect.provide(DatabaseMaintenance.layer),
        ),
      ),
    ),
    awaitLauncherLoss(launcherPid === undefined ? {} : { launcherPid }).pipe(Effect.andThen(Effect.interrupt)),
  );
});

export function runEngineCli() {
  const cli = Command.make(engineName, flags).pipe(
    Command.withDescription(`Run the ${productName} loopback engine.`),
    Command.withSubcommands([claudeHistoryCommand]),
    Command.withHandler(launch),
  );
  Command.run(cli, { version: packageJson.version }).pipe(
    Effect.scoped,
    Effect.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
    NodeRuntime.runMain,
  );
}
