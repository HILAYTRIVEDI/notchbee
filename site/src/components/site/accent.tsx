import type { ReactNode } from "react";

/** The blue-to-violet of the notch glow, used on the words a heading is really about. */
export function Accent({ children }: { children: ReactNode }) {
  return (
    <span className="bg-gradient-to-r from-[#3d6ff5] via-[#6a5cf6] to-[#9b5cf6] box-decoration-clone bg-clip-text pb-[0.06em] text-transparent">
      {children}
    </span>
  );
}
