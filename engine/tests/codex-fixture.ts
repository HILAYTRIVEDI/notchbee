// Minimal app-server fixture. Leaves the turn active until the engine interrupts it.
import { createInterface } from "node:readline";

if (process.argv.includes("--version")) {
  console.log("codex-cli 0.156.1");
  process.exit(0);
}
if (!process.argv.includes("app-server")) process.exit(2);

const threadId = crypto.randomUUID();
const turnId = crypto.randomUUID();
const model = "gpt-6-luna";
const item = {
  type: "agentMessage", id: crypto.randomUUID(), text: "Isolated smoke stream.",
  phase: "final_answer", memoryCitation: null, delivery: null, questions: null,
};
const turn = (status: string) => ({
  id: turnId, items: [], itemsView: "notLoaded", status, error: null,
  startedAt: null, completedAt: null, durationMs: null,
});
const notify = (method: string, fields: object) =>
  console.log(JSON.stringify({ method, params: { threadId, ...fields } }));

for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.id === undefined) continue;
  const reply = (result: object) => console.log(JSON.stringify({ id: request.id, result }));
  switch (request.method) {
    case "initialize":
      reply({ userAgent: "smoke-fixture", codexHome: process.env.CODEX_HOME, platformFamily: "unix", platformOs: "macos" });
      break;
    case "account/read":
      reply({ account: { type: "apiKey" }, requiresOpenaiAuth: false });
      break;
    case "model/list":
      reply({ data: [], nextCursor: null });
      break;
    case "thread/start": {
      const cwd = request.params.cwd;
      reply({
        thread: {
          id: threadId, preview: "", cwd, createdAt: 0, updatedAt: 0, recencyAt: 0,
          status: { type: "idle" }, path: null, ephemeral: true,
          environments: [{ environmentId: "local", cwd, runtimeWorkspaceRoots: [cwd] }],
          extra: null, sessionId: threadId, forkedFromId: null, parentThreadId: null,
          section: null, sectionEnteredAt: null, projectId: null, historyMode: "paginated",
          modelProvider: "openai", model, reasoningEffort: null,
          cliVersion: "0.156.1", source: "cli", originator: "smoke-fixture",
          canAcceptDirectInput: true, threadSource: null,
          agentNickname: null, agentRole: null, gitInfo: null, name: null, daybreakEnabled: null, turns: [],
        },
        model, modelProvider: "openai", cwd, approvalPolicy: "on-request",
        approvalsReviewer: "user", serviceTier: null, disabledPluginIds: [],
        runtimeWorkspaceRoots: [cwd], instructionSources: [],
        sandbox: {
          type: "workspaceWrite", writableRoots: [], networkAccess: false,
          excludeTmpdirEnvVar: false, excludeSlashTmp: false,
        },
        activePermissionProfile: { id: ":workspace", extends: null },
        reasoningEffort: null, multiAgentMode: "explicitRequestOnly",
      });
      break;
    }
    case "turn/start":
      reply({ turn: turn("inProgress") });
      notify("turn/started", { turn: turn("inProgress") });
      notify("item/started", { turnId, startedAtMs: Date.now(), item: { ...item, text: "" } });
      notify("item/agentMessage/delta", { turnId, itemId: item.id, delta: item.text });
      break;
    case "turn/interrupt":
      reply({});
      notify("item/completed", { turnId, completedAtMs: Date.now(), item });
      notify("turn/completed", { turn: turn("interrupted") });
      break;
    default:
      console.log(JSON.stringify({ id: request.id, error: { code: -32601, message: "Fixture method unavailable" } }));
  }
}
