"use client";

import { useEffect, useRef, useState } from "react";
import { motion, useInView, useReducedMotion } from "motion/react";
import { Play } from "lucide-react";
import { cn } from "@/lib/utils";

/** Where the hardware notch sits in a recording, as fractions of the frame. */
export type NotchBox = { left: number; width: number; height: number };

/** The part of the recording worth a closer look, as fractions of the frame, and what to say about it. */
export type Focus = { x: number; y: number; w: number; h: number; caption: string };

type Props = {
  src: string;
  poster: string;
  label: string;
  /** Recorded frame size, so the box holds its aspect ratio before the video loads. */
  aspect: number;
  notch: NotchBox;
  focus?: Focus;
  className?: string;
  onTime?: (seconds: number, duration: number) => void;
};

const CYCLE = 8;
const TIMES = [0, 0.22, 0.34, 0.78, 0.9, 1];

/**
 * A screen recording in a MacBook-style bezel, with the physical notch drawn back in (screen captures can't see
 * it). With a `focus`, the camera eases in on that area, rings it and names it, then pulls back out.
 * It plays only while on screen; with Reduce Motion it holds still and waits for a click.
 */
export function NotchVideo({ src, poster, label, aspect, notch, focus, className, onTime }: Props) {
  const ref = useRef<HTMLVideoElement>(null);
  const frame = useRef<HTMLDivElement>(null);
  const inView = useInView(frame, { amount: 0.45 });
  const reduce = useReducedMotion();
  const [playing, setPlaying] = useState(false);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    if (inView && !reduce) video.play().catch(() => {});
    else video.pause();
  }, [inView, reduce]);

  const zooming = Boolean(focus) && inView && !reduce;
  const scale = focus ? Math.min(2.3, Math.max(1.2, Math.min(0.85 / focus.w, 0.85 / focus.h))) : 1;
  const origin = focus ? `${(focus.x + focus.w / 2) * 100}% ${(focus.y + focus.h / 2) * 100}%` : "50% 50%";
  const loop = { duration: CYCLE, times: TIMES, repeat: Infinity, ease: "easeInOut" as const };

  return (
    <div
      ref={frame}
      className={cn(
        "relative rounded-[22px] bg-[#0d0e12] p-[5px]",
        "shadow-[0_1px_0_0_rgba(255,255,255,0.08)_inset,0_40px_80px_-40px_rgba(10,12,20,0.55),0_12px_30px_-18px_rgba(10,12,20,0.4)]",
        className,
      )}
    >
      <div className="relative overflow-hidden rounded-[17px] bg-black" style={{ aspectRatio: aspect }}>
        <motion.div
          className="absolute inset-0"
          style={{ transformOrigin: origin }}
          animate={zooming ? { scale: [1, 1, scale, scale, 1, 1] } : { scale: 1 }}
          transition={zooming ? loop : { duration: 0.6 }}
        >
          <video
            ref={ref}
            className="absolute inset-0 size-full object-cover"
            src={src}
            poster={poster}
            muted
            loop
            playsInline
            preload="metadata"
            aria-label={label}
            onPlay={() => setPlaying(true)}
            onPause={() => setPlaying(false)}
            onTimeUpdate={(event) => onTime?.(event.currentTarget.currentTime, event.currentTarget.duration)}
          />
          <svg
            aria-hidden
            className="pointer-events-none absolute top-0"
            style={{ left: `${notch.left * 100}%`, width: `${notch.width * 100}%`, height: `${notch.height * 100}%` }}
            viewBox="0 0 208 38"
            preserveAspectRatio="none"
          >
            <path d="M0 0 H208 V27 Q208 38 197 38 H11 Q0 38 0 27 Z" fill="#000" />
          </svg>
          {focus && (
            <motion.div
              aria-hidden
              className="pointer-events-none absolute rounded-[10px] border-[1.5px] border-comet-a shadow-[0_0_0_4px_rgba(61,123,247,0.18),0_0_24px_rgba(61,123,247,0.55)]"
              style={{ left: `${focus.x * 100}%`, top: `${focus.y * 100}%`, width: `${focus.w * 100}%`, height: `${focus.h * 100}%` }}
              animate={zooming ? { opacity: [0, 0, 1, 1, 0, 0] } : { opacity: reduce ? 1 : 0 }}
              transition={zooming ? loop : { duration: 0.3 }}
            />
          )}
        </motion.div>

        {focus && (
          <motion.p
            className="pointer-events-none absolute bottom-3 left-3 flex items-center gap-2 rounded-full bg-white/92 px-3 py-1.5 text-[12.5px] font-medium tracking-tight text-ink shadow-[0_8px_24px_-8px_rgba(10,12,20,0.5)] backdrop-blur"
            animate={zooming ? { opacity: [0, 0, 1, 1, 0, 0], y: [6, 6, 0, 0, 6, 6] } : { opacity: reduce ? 1 : 0, y: 0 }}
            transition={zooming ? loop : { duration: 0.3 }}
          >
            <span className="size-1.5 rounded-full bg-comet-a shadow-[0_0_8px_var(--comet-a)]" />
            {focus.caption}
          </motion.p>
        )}

        {reduce && !playing && (
          <button
            type="button"
            onClick={() => ref.current?.play()}
            className="absolute top-3 right-3 flex items-center gap-1.5 rounded-full bg-white/90 px-3 py-1.5 text-[12.5px] font-medium text-ink shadow"
          >
            <Play className="size-3.5" /> Play
          </button>
        )}
      </div>
    </div>
  );
}
