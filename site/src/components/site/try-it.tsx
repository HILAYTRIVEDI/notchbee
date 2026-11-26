"use client";

import { motion, useReducedMotion } from "motion/react";
import { Accent } from "./accent";
import { NotchDemo } from "./notch-demo";

/** The interactive notch, for visitors who want to poke at it themselves. */
export function TryIt() {
  const reduce = useReducedMotion();

  return (
    <section id="try" className="px-5 pt-8 pb-4 sm:pt-12">
      <motion.div
        initial={reduce ? false : { opacity: 0, y: 40 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, amount: 0.25 }}
        transition={{ duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
      >
        <h2 className="mb-10 text-center font-heading text-[clamp(1.9rem,3.6vw,2.9rem)] leading-[1.02] font-semibold tracking-[-0.045em] text-ink">
          Try it <Accent>right here.</Accent>
        </h2>
        <NotchDemo />
      </motion.div>
    </section>
  );
}
