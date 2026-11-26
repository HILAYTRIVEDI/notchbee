"use client";

import { useEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "motion/react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { GitHubMark, NotchMark } from "./icons";
import { notchPath } from "./notch-shape";
import { GITHUB_URL } from "./site-links";

const HEIGHT = 58;
type Phase = "sweep" | "done" | "rest";

/**
 * The navigation is a notch hanging from the top of the window. On load the app's activity glow sweeps its
 * edge, then it flashes green the way a finished session does. Hovering it runs the sweep again.
 */
export function NotchNav() {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [state, setPhase] = useState<Phase>("sweep");
  const [run, setRun] = useState(0);
  const reduce = useReducedMotion();
  const phase: Phase = reduce ? "rest" : state;

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (phase !== "done") return;
    const timer = setTimeout(() => setPhase("rest"), 1600);
    return () => clearTimeout(timer);
  }, [phase]);

  const replay = () => {
    if (reduce || phase === "sweep") return;
    setRun((value) => value + 1);
    setPhase("sweep");
  };

  const fill = width ? notchPath(width, HEIGHT, 10, 22, true) : "";
  const edge = width ? notchPath(width, HEIGHT, 10, 22, false) : "";

  return (
    <motion.header
      initial={reduce ? false : { y: -HEIGHT - 12 }}
      animate={{ y: 0 }}
      transition={{ type: "spring", stiffness: 260, damping: 30, delay: 0.1 }}
      className="fixed inset-x-0 top-0 z-50 flex justify-center px-2"
    >
      <div ref={ref} onMouseEnter={replay} className="relative w-full max-w-[780px]" style={{ height: HEIGHT }}>
        {width > 0 && (
          <div
            aria-hidden
            className="absolute inset-0 bg-white/55 backdrop-blur-2xl backdrop-saturate-150"
            style={{
              clipPath: `path('${fill}')`,
              boxShadow: "inset 0 -1px 0 rgba(255,255,255,0.7)",
            }}
          />
        )}
        {width > 0 && (
          <svg
            aria-hidden
            className="pointer-events-none absolute inset-0 overflow-visible"
            width={width}
            height={HEIGHT}
            viewBox={`0 0 ${width} ${HEIGHT}`}
          >
            <defs>
              <linearGradient id="comet" x1="0" x2={width} y1="0" y2="0" gradientUnits="userSpaceOnUse">
                <stop offset="0" stopColor="var(--comet-a)" />
                <stop offset="0.55" stopColor="var(--comet-b)" />
                <stop offset="1" stopColor="var(--comet-a)" />
              </linearGradient>
            </defs>
            <path d={edge} fill="none" stroke="rgb(10 12 20 / 0.10)" strokeWidth={1} />
            {phase === "sweep" && (
              <motion.path
                key={run}
                d={edge}
                fill="none"
                stroke="url(#comet)"
                strokeWidth={2.2}
                strokeLinecap="round"
                pathLength={1}
                strokeDasharray="0.24 1.24"
                style={{ filter: "drop-shadow(0 0 6px var(--comet-a)) drop-shadow(0 0 14px var(--comet-b))" }}
                initial={{ strokeDashoffset: 0.24 }}
                animate={{ strokeDashoffset: -1 }}
                transition={{ duration: 1.5, ease: [0.65, 0, 0.35, 1], repeat: 1, repeatType: "reverse" }}
                onAnimationComplete={() => setPhase("done")}
              />
            )}
            {phase === "done" && (
              <motion.path
                d={edge}
                fill="none"
                stroke="var(--done)"
                strokeWidth={1.8}
                strokeLinecap="round"
                style={{ filter: "drop-shadow(0 0 8px var(--done))" }}
                initial={{ opacity: 0 }}
                animate={{ opacity: [0, 1, 0.85, 0] }}
                transition={{ duration: 1.6, times: [0, 0.2, 0.6, 1] }}
              />
            )}
          </svg>
        )}

        <nav aria-label="Main" className="relative flex h-full items-center gap-2 pr-5 pl-6 sm:pr-6 sm:pl-8">
          <a href="#top" className="flex items-center gap-2 rounded-md text-ink">
            <NotchMark className="h-4 w-7" />
            <span className="font-heading text-[17px] font-semibold tracking-[-0.04em]">Notchbee</span>
          </a>
          <div className="ml-6 hidden items-center gap-1 text-[13.5px] tracking-[-0.01em] text-slate md:flex">
            <a href="#how" className="rounded-md px-2.5 py-1.5 transition hover:text-ink">How it works</a>
            <a href="#open-source" className="rounded-md px-2.5 py-1.5 transition hover:text-ink">Open source</a>
          </div>
          <div className="ml-auto flex items-center gap-2">
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className={cn(buttonVariants({ variant: "ghost", size: "sm" }), "gap-1.5 text-slate hover:bg-ink/5 hover:text-ink")}
            >
              <GitHubMark className="size-3.5" />
              <span className="hidden sm:inline">GitHub</span>
            </a>
            <span
              aria-disabled
              title="Download is coming soon"
              className={cn(
                buttonVariants({ size: "sm" }),
                "cursor-not-allowed rounded-full bg-ink px-3 text-white hover:bg-ink",
              )}
            >
              Download
              <span className="rounded-full bg-white/15 px-1.5 py-px text-[10.5px] font-medium">Soon</span>
            </span>
          </div>
        </nav>
      </div>
    </motion.header>
  );
}
