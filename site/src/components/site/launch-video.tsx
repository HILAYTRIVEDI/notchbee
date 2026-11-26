"use client";

import { motion, useReducedMotion } from "motion/react";
import { Accent } from "./accent";

/** The 21-second launch film, with sound. It waits for a click rather than autoplaying. */
export function LaunchVideo() {
  const reduce = useReducedMotion();

  return (
    <section id="video" className="px-5 pt-8 pb-4 sm:pt-12">
      <motion.div
        className="mx-auto max-w-5xl"
        initial={reduce ? false : { opacity: 0, y: 40 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, amount: 0.25 }}
        transition={{ duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
      >
        <h2 className="text-center font-heading text-[clamp(1.9rem,3.6vw,2.9rem)] leading-[1.02] font-semibold tracking-[-0.045em] text-ink">
          See it in <Accent>21 seconds.</Accent>
        </h2>
        <div className="mt-10 rounded-[22px] bg-[#0d0e12] p-[5px] shadow-[0_1px_0_0_rgba(255,255,255,0.08)_inset,0_40px_80px_-40px_rgba(10,12,20,0.55),0_12px_30px_-18px_rgba(10,12,20,0.4)]">
          <video
            className="block aspect-video w-full rounded-[17px] bg-black"
            src="/media/launch.mp4"
            poster="/media/launch.jpg"
            controls
            playsInline
            preload="none"
            aria-label="Notchbee launch video: starting a session, approving a command, the done card and committing from the notch."
          />
        </div>
      </motion.div>
    </section>
  );
}
