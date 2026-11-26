"use client";

import { motion, useReducedMotion } from "motion/react";
import { cn } from "@/lib/utils";
import { Accent } from "./accent";
import { NotchVideo, type Focus, type NotchBox } from "./notch-video";

type Feature = {
  id: string;
  /** The plain lead-in, then the words that carry the accent. */
  title: [string, string];
  body: string;
  video: { src: string; poster: string; label: string; aspect: number; notch: NotchBox; focus: Focus };
};

// Recordings are 2x screen captures taken from the top of the screen; the notch is 208 × 37.5 pt.
const notch = (regionLeft: number, regionWidth: number, regionHeight: number): NotchBox => ({
  left: (751 - regionLeft) / regionWidth,
  width: 208 / regionWidth,
  height: 37.5 / regionHeight,
});
const media = (name: string) => ({ src: `/media/${name}.mp4`, poster: `/media/${name}.jpg` });

const FEATURES: Feature[] = [
  {
    id: "start",
    title: ["Start a session ", "in seconds."],
    body: "Pick a project, a provider and a model, then type or dictate what you want. The prompt is focused the moment the panel opens, and it grows as you write.",
    video: {
      ...media("new-session"),
      label: "The New tab opens with the prompt focused and example prompts cycling through it.",
      aspect: 1240 / 660,
      notch: notch(545, 620, 330),
      focus: { x: 0.05, y: 0.6, w: 0.62, h: 0.26, caption: "Focused, with ideas to start from" },
    },
  },
  {
    id: "glow",
    title: ["It glows while ", "your agents work."],
    body: "A comet of light runs along the edge of the notch for as long as a session is running. No spinner, no extra window. Just a glance at the top of your screen.",
    video: {
      ...media("glow"),
      label: "Light sweeps along the edge of the notch while a session runs.",
      aspect: 1200 / 260,
      notch: notch(555, 600, 130),
      focus: { x: 0.27, y: 0, w: 0.46, h: 0.55, caption: "Running, at a glance" },
    },
  },
  {
    id: "attention",
    title: ["It taps you ", "on the shoulder."],
    body: "When an agent wants approval or has a question, the notch drops down to say so, then keeps a marker lit until you’ve answered.",
    video: {
      ...media("attention"),
      label: "The notch drops down with “Claude needs input”, then keeps a yellow marker.",
      aspect: 1240 / 300,
      notch: notch(545, 620, 150),
      focus: { x: 0.17, y: 0, w: 0.66, h: 0.56, caption: "Claude needs input" },
    },
  },
  {
    id: "approve",
    title: ["Approve commands ", "without switching apps."],
    body: "See the exact command an agent wants to run, then approve it with ⌘↵ or deny it. The session picks up the moment you decide.",
    video: {
      ...media("approval"),
      label: "A shell command waits for approval with Deny and Approve buttons.",
      aspect: 1240 / 1200,
      notch: notch(545, 620, 600),
      focus: { x: 0.1, y: 0.19, w: 0.8, h: 0.19, caption: "Approve ⌘↵ or deny" },
    },
  },
  {
    id: "answer",
    title: ["Answer questions ", "without losing focus."],
    body: "Multiple-choice questions arrive as options you can click or pick with a number key. Optional ones can be skipped.",
    video: {
      ...media("question"),
      label: "A question card asks which database to target, with three options.",
      aspect: 1240 / 1360,
      notch: notch(545, 620, 680),
      focus: { x: 0.1, y: 0.3, w: 0.8, h: 0.34, caption: "Pick an option and carry on" },
    },
  },
  {
    id: "done",
    title: ["It turns green ", "when the work is done."],
    body: "The edge glows green and a card shows what finished and which agent finished it. One click on View takes you to the result.",
    video: {
      ...media("done"),
      label: "A green-edged card says “Frontend build, Claude finished” with a View button.",
      aspect: 1200 / 280,
      notch: notch(555, 600, 140),
      focus: { x: 0.66, y: 0.28, w: 0.22, h: 0.4, caption: "View the result" },
    },
  },
  {
    id: "read",
    title: ["Read the whole reply, ", "properly formatted."],
    body: "Markdown, tables, highlighted code, plans and tool calls all render in the notch. Copy any message, or reply right below it.",
    video: {
      ...media("thread"),
      label: "A thread shows a formatted table, a checklist and a reply box.",
      aspect: 1240 / 1360,
      notch: notch(545, 620, 680),
      focus: { x: 0.1, y: 0.24, w: 0.8, h: 0.26, caption: "Tables, code and plans" },
    },
  },
  {
    id: "ship",
    title: ["Commit, push and ", "open the pull request."],
    body: "Switch branches, review what changed, write a commit message or have one written, push, then check or merge the pull request.",
    video: {
      ...media("workspace"),
      label: "The workspace menu shows the branch, an open pull request and Commit, Push and Pull buttons.",
      aspect: 1240 / 1360,
      notch: notch(545, 620, 680),
      focus: { x: 0.08, y: 0.42, w: 0.84, h: 0.24, caption: "Commit · push · merge" },
    },
  },
  {
    id: "glance",
    title: ["Hover to see ", "every session."],
    body: "Point at the notch to see what’s running, what’s waiting and what’s finished. The session that needs you is always first.",
    video: {
      ...media("hover"),
      label: "Hovering the notch opens a list of sessions with All sessions and New buttons.",
      aspect: 1200 / 520,
      notch: notch(555, 600, 260),
      focus: { x: 0.52, y: 0.65, w: 0.32, h: 0.18, caption: "All sessions, one hover" },
    },
  },
  {
    id: "find",
    title: ["Find any session ", "in a second."],
    body: "Search by title, project, branch or provider, switch between active and archived, and resolve finished work with one click.",
    video: {
      ...media("sessions"),
      label: "The sessions list with search, Active, Archived and All filters, and four sessions.",
      aspect: 1240 / 1120,
      notch: notch(545, 620, 560),
      focus: { x: 0.1, y: 0.13, w: 0.8, h: 0.11, caption: "Search, filter, resolve" },
    },
  },
];

export function Features() {
  const reduce = useReducedMotion();
  const rise = (delay = 0) =>
    reduce
      ? {}
      : {
          initial: { opacity: 0, y: 32 },
          whileInView: { opacity: 1, y: 0 },
          viewport: { once: true, amount: 0.25 },
          transition: { duration: 0.8, delay, ease: [0.22, 1, 0.36, 1] as const },
        };

  return (
    <section id="how" className="px-5 pt-20 pb-28 sm:pt-28">
      <motion.div {...rise()} className="mx-auto max-w-3xl text-center">
        <h2 className="font-heading text-[clamp(2.2rem,5vw,3.9rem)] leading-[0.98] font-semibold tracking-[-0.045em] text-ink">
          From the first prompt <Accent>to the pull request.</Accent>
        </h2>
        <p className="mx-auto mt-5 max-w-xl text-[17px] leading-relaxed tracking-[-0.01em] text-slate">
          Everything here happens in the notch, without leaving the app you’re working in.
        </p>
      </motion.div>

      <div className="mx-auto mt-24 flex max-w-6xl flex-col gap-28 sm:mt-32 sm:gap-40">
        {FEATURES.map((feature, index) => {
          const tall = feature.video.aspect < 1.4;
          const flipped = index % 2 === 1;
          return (
            <article
              key={feature.id}
              id={feature.id}
              className={cn(
                "grid items-center gap-10 lg:gap-20",
                flipped ? "lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]" : "lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]",
              )}
            >
              <motion.div {...rise()} className={cn("max-w-md", flipped && "lg:order-2 lg:justify-self-end")}>
                <h3 className="font-heading text-[clamp(1.9rem,3.6vw,2.9rem)] leading-[1.02] font-semibold tracking-[-0.045em] text-ink">
                  {feature.title[0]}
                  <Accent>{feature.title[1]}</Accent>
                </h3>
                <p className="mt-5 text-[16.5px] leading-relaxed tracking-[-0.01em] text-slate">{feature.body}</p>
              </motion.div>
              <motion.div
                {...rise(0.1)}
                className={cn("w-full", flipped && "lg:order-1", tall && "mx-auto max-w-[460px]")}
              >
                <NotchVideo {...feature.video} />
              </motion.div>
            </article>
          );
        })}
      </div>
    </section>
  );
}
