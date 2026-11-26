"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import {
  ArrowUpRight,
  Check,
  ChevronDown,
  ChevronUp,
  Code2,
  Cpu,
  Ellipsis,
  Folder,
  GitBranch,
  Mic,
  RotateCcw,
  Send,
  Settings,
  ShieldHalf,
  Sparkle,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { notchPath } from "./notch-shape";

/**
 * A working miniature of Notchbee at the app's real point sizes, sitting on the screen top of a MacBook.
 * It runs the whole loop: hover for sessions, start one, watch it glow, approve its command, see it turn green,
 * read the result, commit and push.
 */

type Stage = "idle" | "hover" | "new" | "running" | "approval" | "done" | "thread";
type Session = { id: string; title: string; provider: "claude" | "codex"; status: string; tone: string; time: string };

const NOTCH = { w: 208, h: 37 };
const EAR = 8;
const SHELL: Record<Stage, { w: number; h: number; r: number }> = {
  idle: { w: NOTCH.w, h: NOTCH.h, r: 10 },
  running: { w: NOTCH.w, h: NOTCH.h, r: 10 },
  hover: { w: 410, h: NOTCH.h + 128, r: 18 },
  approval: { w: 440, h: NOTCH.h + 104, r: 18 },
  done: { w: 430, h: NOTCH.h + 58, r: 18 },
  new: { w: 530, h: NOTCH.h + 246, r: 20 },
  thread: { w: 530, h: NOTCH.h + 330, r: 20 },
};

const HINTS: Record<Stage, string> = {
  idle: "Hover or tap the notch to see your sessions.",
  hover: "Click New to start a session.",
  new: "Type what you want, or just press Send to use the suggestion.",
  running: "Claude is working. Watch the edge of the notch.",
  approval: "Claude wants to run a command. Approve it.",
  done: "Done. Click View to read the result.",
  thread: "Commit and push the change, then resolve the session.",
};

const IDEAS = ["Add a dark mode toggle to settings", "Fix the failing tests in auth", "Explain how the sync engine works"];

const STARTING: Session[] = [
  { id: "a", title: "Fix flaky login test", provider: "claude", status: "Done", tone: "#33d499", time: "2h" },
  { id: "b", title: "Refactor the API client", provider: "codex", status: "Idle", tone: "#737a8c", time: "1d" },
];

export function NotchDemo() {
  const reduce = useReducedMotion();
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [stage, setStage] = useState<Stage>("idle");
  const [prompt, setPrompt] = useState("");
  const [idea, setIdea] = useState(0);
  const [task, setTask] = useState(IDEAS[0]);
  const [sessions, setSessions] = useState<Session[]>(STARTING);
  const [pushed, setPushed] = useState(false);
  const leave = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    const node = box.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  // The agent's side of the story: work, ask, work, finish.
  useEffect(() => {
    if (stage !== "running") return;
    const asked = sessions[0]?.status === "Running";
    const timer = setTimeout(
      () => {
        if (asked) {
          setSessions((list) => list.map((s, i) => (i === 0 ? { ...s, status: "Needs approval", tone: "#fac024" } : s)));
          setStage("approval");
        } else {
          setSessions((list) => list.map((s, i) => (i === 0 ? { ...s, status: "Done", tone: "#33d499", time: "now" } : s)));
          setStage("done");
        }
      },
      asked ? 2600 : 2000,
    );
    return () => clearTimeout(timer);
  }, [stage, sessions]);

  useEffect(() => {
    if (stage !== "new" || prompt || reduce) return;
    const timer = setInterval(() => setIdea((value) => (value + 1) % IDEAS.length), 2600);
    return () => clearInterval(timer);
  }, [stage, prompt, reduce]);

  const W = width && width < 700 ? 560 : 1000;
  const H = 440;
  const scale = width ? width / W : 1;
  const shell = SHELL[stage];

  const open = (next: Stage) => {
    clearTimeout(leave.current);
    setStage(next);
  };
  const send = () => {
    const title = (prompt.trim() || IDEAS[idea]).replace(/\.$/, "");
    setTask(title);
    setPushed(false);
    setPrompt("");
    setSessions((list) => [
      { id: String(Date.now()), title, provider: "claude", status: "Running", tone: "#73a8fd", time: "now" },
      ...list.slice(0, 1),
    ]);
    setStage("running");
  };
  const approve = () => {
    setSessions((list) => list.map((s, i) => (i === 0 ? { ...s, status: "Approved", tone: "#73a8fd" } : s)));
    setStage("running");
  };
  const restart = () => {
    setSessions(STARTING);
    setPrompt("");
    setPushed(false);
    setStage("idle");
  };

  const glow = stage === "running" ? "running" : stage === "done" ? "done" : null;

  return (
    <div className="mx-auto max-w-6xl">
      <div className="rounded-[26px] bg-[#0d0e12] p-[6px] shadow-[0_1px_0_0_rgba(255,255,255,0.08)_inset,0_50px_100px_-50px_rgba(10,12,20,0.6),0_16px_40px_-24px_rgba(10,12,20,0.45)]">
        <div ref={box} className="relative overflow-hidden rounded-[20px]" style={{ height: H * scale }}>
          <div
            className="absolute top-0 left-0 origin-top-left select-none"
            style={{
              width: W,
              height: H,
              transform: `scale(${scale})`,
              backgroundImage: "url(/media/tahoe-top.jpg)",
              backgroundSize: `${(1200 / W) * 100}% auto`,
              backgroundPosition: "center top",
            }}
          >
            {/* The notch and everything that grows out of it. */}
            <div
              className="absolute top-0"
              style={{ left: W / 2 - shell.w / 2 - EAR }}
              onMouseEnter={() => stage === "idle" && open("hover")}
              onMouseLeave={() => {
                if (stage === "hover") leave.current = setTimeout(() => setStage("idle"), 350);
              }}
            >
              <motion.div
                className="relative"
                initial={false}
                animate={{ width: shell.w + 2 * EAR, height: shell.h }}
                transition={reduce ? { duration: 0 } : { type: "spring", stiffness: 380, damping: 34 }}
              >
                <Ear side="left" />
                <Ear side="right" />
                <motion.div
                  className="absolute inset-y-0 overflow-hidden bg-black text-[12px] text-white"
                  style={{ left: EAR, right: EAR }}
                  initial={false}
                  animate={{ borderBottomLeftRadius: shell.r, borderBottomRightRadius: shell.r }}
                >
                  {stage === "idle" && (
                    <button
                      type="button"
                      aria-label="Open the notch"
                      onClick={() => open("hover")}
                      onFocus={() => open("hover")}
                      className="absolute inset-0 cursor-pointer"
                    />
                  )}
                  <AnimatePresence mode="wait" initial={false}>
                    {stage !== "idle" && stage !== "running" && (
                      <motion.div
                        key={stage}
                        className="absolute inset-x-0 bottom-0"
                        style={{ top: NOTCH.h }}
                        initial={{ opacity: 0, filter: "blur(4px)" }}
                        animate={{ opacity: 1, filter: "blur(0px)", transition: { duration: 0.2, delay: 0.12 } }}
                        exit={{ opacity: 0, transition: { duration: 0.08 } }}
                      >
                        {stage === "hover" && (
                          <HoverCard sessions={sessions} onNew={() => open("new")} onOpen={() => open("thread")} />
                        )}
                        {stage === "new" && (
                          <NewPanel
                            prompt={prompt}
                            setPrompt={setPrompt}
                            idea={IDEAS[idea]}
                            onSend={send}
                            onClose={() => setStage("idle")}
                          />
                        )}
                        {stage === "approval" && (
                          <ApprovalCard title={task} onApprove={approve} onDeny={approve} />
                        )}
                        {stage === "done" && <DoneCard title={task} onView={() => open("thread")} />}
                        {stage === "thread" && (
                          <ThreadPanel
                            title={task}
                            pushed={pushed}
                            onPush={() => setPushed(true)}
                            onResolve={() => {
                              setSessions((list) => list.map((s, i) => (i === 0 ? { ...s, status: "Resolved", tone: "#737a8c" } : s)));
                              setStage("idle");
                            }}
                            onClose={() => setStage("idle")}
                          />
                        )}
                      </motion.div>
                    )}
                  </AnimatePresence>
                </motion.div>
                {glow && <EdgeGlow mode={glow} width={shell.w + 2 * EAR} height={shell.h} radius={shell.r} reduce={!!reduce} />}
              </motion.div>
            </div>

            <AnimatePresence>
              {stage === "idle" && (
                <motion.div
                  className="pointer-events-none absolute left-1/2 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-white/80 px-3.5 py-1.5 text-[13px] font-medium tracking-tight text-ink shadow-[0_8px_24px_-10px_rgba(10,12,20,0.45)] backdrop-blur"
                  style={{ top: 62 }}
                  initial={{ opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: reduce ? 0 : [0, -4, 0] }}
                  exit={{ opacity: 0 }}
                  transition={{ y: { duration: 1.8, repeat: Infinity, ease: "easeInOut" }, opacity: { duration: 0.3 } }}
                >
                  <ChevronUp className="size-3.5" />
                  Hover or tap the notch
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </div>
      </div>

      <div className="mt-5 flex min-h-8 flex-wrap items-center justify-center gap-x-4 gap-y-2 text-[15px] tracking-[-0.01em] text-slate" aria-live="polite">
        <AnimatePresence mode="wait" initial={false}>
          <motion.span
            key={stage}
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
            transition={{ duration: 0.18 }}
          >
            {HINTS[stage]}
          </motion.span>
        </AnimatePresence>
        {stage !== "idle" && (
          <button
            type="button"
            onClick={restart}
            className="inline-flex items-center gap-1 rounded-full px-2 py-1 text-[14px] font-medium text-ink/70 transition hover:bg-ink/5 hover:text-ink"
          >
            <RotateCcw className="size-3.5" /> Start over
          </button>
        )}
      </div>
    </div>
  );
}

/** The concave fillet where the notch meets the top edge of the screen. */
function Ear({ side }: { side: "left" | "right" }) {
  return (
    <svg
      aria-hidden
      width={EAR}
      height={EAR}
      viewBox="0 0 8 8"
      className="absolute top-0"
      style={side === "left" ? { left: 0 } : { right: 0, transform: "scaleX(-1)" }}
    >
      <path d="M0 0 H8 V8 C8 3.6 4.4 0 0 0 Z" fill="#000" />
    </svg>
  );
}

function EdgeGlow({ mode, width, height, radius, reduce }: { mode: "running" | "done"; width: number; height: number; radius: number; reduce: boolean }) {
  const edge = notchPath(width + 3, height + 1.5, EAR, radius, false);
  const color = mode === "done" ? "#33d499" : "url(#demo-comet)";
  return (
    <svg aria-hidden className="pointer-events-none absolute top-0 overflow-visible" style={{ left: -1.5 }} width={width + 3} height={height + 1.5}>
      <defs>
        <linearGradient id="demo-comet" x1="0" x2="1">
          <stop offset="0" stopColor="#5ad8ff" />
          <stop offset="0.5" stopColor="#73a8fd" />
          <stop offset="1" stopColor="#9e73ff" />
        </linearGradient>
      </defs>
      {mode === "running" ? (
        <>
          <path d={edge} fill="none" stroke="#73a8fd" strokeOpacity={0.35} strokeWidth={1.5} style={{ filter: "blur(1.5px)" }} />
          <motion.path
            d={edge}
            fill="none"
            stroke={color}
            strokeWidth={2.4}
            strokeLinecap="round"
            pathLength={1}
            strokeDasharray="0.32 1.32"
            style={{ filter: "drop-shadow(0 0 5px #73a8fd) drop-shadow(0 0 12px #9e73ff)" }}
            initial={{ strokeDashoffset: 0.32 }}
            animate={reduce ? { strokeDashoffset: -0.3 } : { strokeDashoffset: [0.32, -1] }}
            transition={reduce ? { duration: 0 } : { duration: 1.6, ease: [0.65, 0, 0.35, 1], repeat: Infinity, repeatType: "reverse" }}
          />
        </>
      ) : (
        <motion.path
          d={edge}
          fill="none"
          stroke={color}
          strokeWidth={2}
          strokeLinecap="round"
          style={{ filter: "drop-shadow(0 0 6px #33d499) drop-shadow(0 0 14px #33d499)" }}
          animate={reduce ? { opacity: 1 } : { opacity: [0.55, 1, 0.55] }}
          transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
        />
      )}
    </svg>
  );
}

function ProviderBadge({ provider }: { provider: Session["provider"] }) {
  return provider === "claude" ? (
    <span className="grid size-5 shrink-0 place-items-center rounded-[6px] bg-[#2b160f] ring-1 ring-[#e07a5f]/30">
      <Sparkle className="size-3 fill-[#e07a5f] text-[#e07a5f]" />
    </span>
  ) : (
    <span className="grid size-5 shrink-0 place-items-center rounded-[6px] bg-white/[0.08] ring-1 ring-white/15">
      <Code2 className="size-3 text-white/80" />
    </span>
  );
}

function Pill({ children, onClick, primary, className }: { children: ReactNode; onClick?: () => void; primary?: boolean; className?: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "inline-flex h-[26px] cursor-pointer items-center gap-1.5 rounded-full px-3 text-[11.5px] font-semibold transition active:scale-95",
        primary
          ? "bg-gradient-to-br from-[#73a8fd] to-[#4d61eb] text-white shadow-[0_0_14px_rgba(77,97,235,0.55)] ring-1 ring-white/25 hover:brightness-110"
          : "bg-white/[0.05] text-white/85 ring-1 ring-white/10 hover:bg-white/[0.09] hover:text-white",
        className,
      )}
    >
      {children}
    </button>
  );
}

function HoverCard({ sessions, onNew, onOpen }: { sessions: Session[]; onNew: () => void; onOpen: () => void }) {
  return (
    <div className="flex h-full flex-col px-3 pt-2 pb-2.5">
      {sessions.map((session, index) => (
        <button
          key={session.id}
          type="button"
          onClick={index === 0 && session.status !== "Done" && session.status !== "Idle" ? onOpen : undefined}
          className="flex h-8 items-center gap-2 rounded-lg px-2 text-left transition hover:bg-white/[0.07]"
        >
          <ProviderBadge provider={session.provider} />
          <span className="flex-1 truncate text-[12.5px] font-medium">{session.title}</span>
          <span className="size-1.5 rounded-full" style={{ background: session.tone }} />
          <span className="w-7 text-right text-[11px] text-white/45 tabular-nums">{session.time}</span>
        </button>
      ))}
      <div className="mt-auto flex items-center justify-end gap-1.5 px-1">
        <Pill>All sessions</Pill>
        <Pill primary onClick={onNew}>
          <span className="text-[13px] leading-none">+</span> New
        </Pill>
      </div>
    </div>
  );
}

function Chip({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <div className="flex h-10 items-center gap-2.5 rounded-[10px] bg-white/[0.04] px-2.5 ring-1 ring-white/[0.08]">
      <span className="text-[#73a8fd]">{icon}</span>
      <span className="flex-1 leading-tight">
        <span className="block text-[9.5px] font-medium text-white/40">{label}</span>
        <span className="block text-[11.5px] font-medium">{value}</span>
      </span>
      <ChevronDown className="size-3 text-white/35" />
    </div>
  );
}

function PanelHeader({ tab, onClose, status }: { tab: "New" | "Thread"; onClose: () => void; status?: ReactNode }) {
  const tabs = tab === "Thread" ? ["Sessions", "Thread", "New"] : ["Sessions", "New"];
  return (
    <div className="flex items-center gap-2 border-b border-white/[0.08] pb-2">
      <div className="flex items-center gap-0.5 rounded-full bg-white/[0.04] p-0.5 ring-1 ring-white/[0.08]">
        {tabs.map((name) => (
          <span
            key={name}
            className={cn(
              "rounded-full px-2.5 py-1 text-[11px] font-medium",
              name === tab ? "bg-white font-semibold text-black" : "text-white/55",
            )}
          >
            {name}
          </span>
        ))}
      </div>
      <span className="ml-auto">{status}</span>
      <span className="grid size-7 place-items-center rounded-full bg-white/[0.04] text-white/60 ring-1 ring-white/[0.08]">
        <Settings className="size-3.5" />
      </span>
      <button
        type="button"
        onClick={onClose}
        aria-label="Collapse"
        className="grid h-7 w-8 cursor-pointer place-items-center rounded-[7px] bg-white/[0.14] transition hover:bg-white/[0.2]"
      >
        <ChevronUp className="size-3.5" />
      </button>
    </div>
  );
}

function RoundButton({ children, onClick, primary, label }: { children: ReactNode; onClick?: () => void; primary?: boolean; label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className={cn(
        "grid size-[34px] shrink-0 cursor-pointer place-items-center rounded-full transition active:scale-95",
        primary
          ? "bg-gradient-to-br from-[#73a8fd] to-[#4d61eb] text-white shadow-[0_0_14px_rgba(77,97,235,0.6)] ring-1 ring-white/25 hover:scale-105"
          : "bg-white/[0.04] text-white/85 ring-1 ring-white/10 hover:bg-white/[0.09]",
      )}
    >
      {children}
    </button>
  );
}

function NewPanel({
  prompt,
  setPrompt,
  idea,
  onSend,
  onClose,
}: {
  prompt: string;
  setPrompt: (value: string) => void;
  idea: string;
  onSend: () => void;
  onClose: () => void;
}) {
  const field = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const timer = setTimeout(() => field.current?.focus({ preventScroll: true }), 260);
    return () => clearTimeout(timer);
  }, []);

  return (
    <div className="flex h-full flex-col px-3.5 pt-1 pb-3">
      <PanelHeader tab="New" onClose={onClose} />
      <div className="mt-2.5 grid grid-cols-2 gap-2">
        <Chip icon={<Folder className="size-3.5" />} label="Project" value="acme-web" />
        <Chip icon={<Cpu className="size-3.5" />} label="Provider" value="Claude" />
        <Chip icon={<Sparkle className="size-3.5" />} label="Model" value="Claude Opus 5.5" />
        <Chip icon={<ShieldHalf className="size-3.5" />} label="Runtime" value="Approval required" />
      </div>
      <div className="mt-2.5 flex items-center justify-between">
        <span className="flex items-center gap-2 text-[11px] text-white/55">
          <span className="relative h-[5px] w-11 overflow-hidden rounded-full bg-white/10">
            <span className="absolute inset-y-0 left-0 w-[86%] rounded-full bg-[#33d499] shadow-[0_0_6px_#33d499]" />
          </span>
          86% weekly left
        </span>
        <Pill>+ Connect provider</Pill>
      </div>
      <form
        className="mt-auto flex items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault();
          onSend();
        }}
      >
        <div className="relative flex-1 rounded-[14px] bg-[#101010] ring-1 ring-[#4d61eb] shadow-[0_0_0_3px_rgba(77,97,235,0.25)]">
          <textarea
            ref={field}
            rows={1}
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                onSend();
              }
            }}
            aria-label="Prompt"
            className="block h-[42px] w-full resize-none bg-transparent px-3.5 py-[11px] text-[14px] text-white outline-none placeholder:text-transparent"
            placeholder={idea}
          />
          {!prompt && (
            <AnimatePresence mode="wait" initial={false}>
              <motion.span
                key={idea}
                className="pointer-events-none absolute top-[11px] left-3.5 text-[14px] text-white/40"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.3 }}
              >
                {idea}…
              </motion.span>
            </AnimatePresence>
          )}
        </div>
        <RoundButton label="Dictate">
          <Mic className="size-3.5" />
        </RoundButton>
        <RoundButton label="Send" primary onClick={onSend}>
          <Send className="size-3.5 -translate-x-px translate-y-px" />
        </RoundButton>
      </form>
    </div>
  );
}

function ApprovalCard({ title, onApprove, onDeny }: { title: string; onApprove: () => void; onDeny: () => void }) {
  return (
    <div className="flex h-full flex-col justify-center gap-2 px-4 pb-2">
      <div className="flex items-center gap-2">
        <span className="size-1.5 rounded-full bg-[#fac024] shadow-[0_0_6px_#fac024]" />
        <span className="text-[12.5px] font-semibold">Claude needs approval</span>
        <span className="ml-auto max-w-[170px] truncate text-[11px] text-white/45">{title}</span>
      </div>
      <div className="flex items-center gap-2">
        <code className="flex-1 truncate font-sans rounded-[7px] bg-white/[0.06] px-2.5 py-1.5 text-[11.5px] font-medium text-white/90">
          npm test -- settings
        </code>
        <Pill onClick={onDeny}>Deny</Pill>
        <Pill primary onClick={onApprove}>
          Approve <span className="opacity-60">⌘↵</span>
        </Pill>
      </div>
    </div>
  );
}

function DoneCard({ title, onView }: { title: string; onView: () => void }) {
  return (
    <div className="flex h-full items-center gap-2.5 px-3.5 pb-1">
      <span className="grid size-[30px] shrink-0 place-items-center rounded-full bg-[#33d499]/15 ring-1 ring-[#33d499]/40">
        <Check className="size-3.5 stroke-[3] text-[#33d499]" />
      </span>
      <span className="min-w-0 flex-1 leading-tight">
        <span className="block truncate text-[12.5px] font-semibold">{title}</span>
        <span className="block text-[11px] text-white/55">Claude finished</span>
      </span>
      <Pill primary onClick={onView}>
        <ArrowUpRight className="size-3" /> View
      </Pill>
    </div>
  );
}

function ThreadPanel({
  title,
  pushed,
  onPush,
  onResolve,
  onClose,
}: {
  title: string;
  pushed: boolean;
  onPush: () => void;
  onResolve: () => void;
  onClose: () => void;
}) {
  return (
    <div className="flex h-full flex-col px-3.5 pt-1 pb-3">
      <PanelHeader tab="Thread" onClose={onClose} />
      <div className="mt-2 flex items-center gap-2 rounded-[10px] bg-white/[0.04] px-2.5 py-2">
        <ProviderBadge provider="claude" />
        <span className="min-w-0 flex-1 leading-tight">
          <span className="block truncate text-[13px] font-semibold">{title}</span>
          <span className="flex items-center gap-1 text-[10.5px] text-white/55">
            <span className="size-1.5 rounded-full bg-[#33d499]" /> Completed · 3 files · <span className="text-[#33d499]">+42</span>{" "}
            <span className="text-[#f87878]">−8</span>
          </span>
        </span>
        <span className="grid size-7 place-items-center rounded-full bg-white/[0.04] text-white/60 ring-1 ring-white/[0.08]">
          <ArrowUpRight className="size-3.5" />
        </span>
        <button
          type="button"
          onClick={onResolve}
          aria-label="Resolve"
          className="grid size-7 cursor-pointer place-items-center rounded-full bg-[#33d499]/10 text-[#33d499] ring-1 ring-[#33d499]/30 transition hover:bg-[#33d499]/20"
        >
          <Check className="size-3.5 stroke-[3]" />
        </button>
        <span className="grid size-7 place-items-center rounded-full bg-white/[0.04] text-white/60 ring-1 ring-white/[0.08]">
          <Ellipsis className="size-3.5" />
        </span>
      </div>

      <div className="mt-2.5 flex-1 space-y-2 overflow-hidden text-[12px] leading-relaxed">
        <div className="ml-auto w-fit max-w-[70%] rounded-[12px] bg-white/[0.08] px-3 py-1.5">{title}</div>
        <div className="text-white/85">
          Done. Here’s what changed:
          <ul className="mt-1 space-y-0.5 text-white/75">
            <li>
              • <span className="rounded bg-white/[0.08] px-1 text-[11px]">SettingsView.swift</span> has the new toggle
            </li>
            <li>
              • <span className="rounded bg-white/[0.08] px-1 text-[11px]">Theme.swift</span> picks the palette
            </li>
            <li>• All 24 tests pass</li>
          </ul>
        </div>
      </div>

      <div className="mt-2 flex items-center gap-2 rounded-[10px] bg-white/[0.04] px-2.5 py-1.5 ring-1 ring-white/[0.08]">
        <GitBranch className="size-3.5 text-[#73a8fd]" />
        <span className="flex-1 text-[11.5px] font-medium">feature/dark-mode</span>
        <AnimatePresence mode="wait" initial={false}>
          {pushed ? (
            <motion.span
              key="pushed"
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              className="inline-flex items-center gap-1 text-[11.5px] font-semibold text-[#33d499]"
            >
              <Check className="size-3.5 stroke-[3]" /> Pushed
            </motion.span>
          ) : (
            <motion.span key="push" exit={{ opacity: 0 }}>
              <Pill primary onClick={onPush}>
                Commit &amp; push
              </Pill>
            </motion.span>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}
