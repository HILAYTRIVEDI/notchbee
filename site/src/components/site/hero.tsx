"use client";

import { motion, useReducedMotion } from "motion/react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Accent } from "./accent";
import { AppleMark, GitHubMark } from "./icons";
import { NotchDemo } from "./notch-demo";
import { DOWNLOAD_URL, GITHUB_URL } from "./site-links";

const LINES: { word: string; accent?: boolean }[][] = [
  [{ word: "Your" }, { word: "coding" }, { word: "agents," }],
  [{ word: "living" }, { word: "in", accent: true }, { word: "the", accent: true }, { word: "notch.", accent: true }],
];

export function Hero() {
  const reduce = useReducedMotion();

  return (
    <section id="top" className="relative isolate px-5 pt-32 pb-12 sm:pt-44 sm:pb-16">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[900px] bg-[radial-gradient(60%_60%_at_50%_0%,rgba(61,123,247,0.16)_0%,rgba(124,92,246,0.07)_45%,rgba(243,245,249,0)_100%)]"
      />
      <div className="mx-auto max-w-5xl text-center">
        <h1 className="font-heading text-[clamp(2.15rem,7.2vw,5.6rem)] leading-[0.95] font-semibold tracking-[-0.05em] text-ink">
          {LINES.map((line, row) => (
            <span key={row} className="block">
              {line.map(({ word, accent }, column) => {
                const index = row * 3 + column;
                const text = (
                  <>
                    {word}
                    {column < line.length - 1 ? " " : null}
                  </>
                );
                return (
                  <motion.span
                    key={word}
                    className="inline-block"
                    initial={reduce ? false : { y: "0.5em", opacity: 0, filter: "blur(8px)" }}
                    animate={{ y: 0, opacity: 1, filter: "blur(0px)" }}
                    transition={{ duration: 0.7, delay: 0.35 + index * 0.06, ease: [0.22, 1, 0.36, 1] }}
                  >
                    {accent ? <Accent>{text}</Accent> : text}
                  </motion.span>
                );
              })}
            </span>
          ))}
        </h1>

        <motion.p
          className="mx-auto mt-7 max-w-[34rem] text-[18px] leading-relaxed tracking-[-0.015em] text-slate"
          initial={reduce ? false : { opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 0.85 }}
        >
          Run Claude and Codex sessions from your MacBook’s notch. It glows while they work, asks when they need you,
          and turns green when they’re done.
        </motion.p>

        <motion.div
          className="mt-9 flex flex-wrap items-center justify-center gap-3"
          initial={reduce ? false : { opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 1.0 }}
        >
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            className={cn(
              buttonVariants({ size: "lg" }),
              "h-11 gap-2 rounded-full bg-ink px-5 text-[15px] tracking-[-0.01em] text-white shadow-[0_8px_20px_-8px_rgba(10,12,20,0.6)] hover:bg-ink/90",
            )}
          >
            <GitHubMark className="size-4" />
            View on GitHub
          </a>
          <a
            href={DOWNLOAD_URL}
            target="_blank"
            rel="noreferrer"
            className={cn(
              buttonVariants({ variant: "outline", size: "lg" }),
              "h-11 gap-2 rounded-full border-ink/12 bg-white/70 px-5 text-[15px] tracking-[-0.01em] text-ink hover:bg-white",
            )}
          >
            <AppleMark className="size-4 -translate-y-px" />
            Download for macOS
            <span className="rounded-full bg-ink/[0.06] px-2 py-0.5 text-[11px] font-medium text-slate">macOS 26+</span>
          </a>
        </motion.div>
      </div>

      <motion.div
        className="mt-16"
        initial={reduce ? false : { opacity: 0, y: 40, scale: 0.97 }}
        animate={{ opacity: 1, y: 0, scale: 1 }}
        transition={{ duration: 1, delay: 1.1, ease: [0.22, 1, 0.36, 1] }}
      >
        <NotchDemo />
      </motion.div>
    </section>
  );
}
