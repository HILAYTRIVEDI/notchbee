import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Accent } from "./accent";
import { AppleMark, GitHubMark, NotchMark } from "./icons";
import { DOWNLOAD_URL, GITHUB_URL } from "./site-links";

const FACTS = ["macOS 26 on Apple Silicon", "Codex, Claude, Cursor and more", "Dictation stays on your Mac", "Open source"];

export function Closing() {
  return (
    <section id="open-source" className="px-5 pb-28">
      <div className="relative mx-auto max-w-5xl overflow-hidden rounded-[32px] border border-hairline bg-surface px-6 pt-24 pb-16 text-center shadow-[0_40px_80px_-50px_rgba(10,12,20,0.35)] sm:px-16">
        <div
          aria-hidden
          className="pointer-events-none absolute -top-px left-1/2 h-11 w-[36%] min-w-52 -translate-x-1/2 rounded-b-[22px] bg-notch shadow-[0_8px_30px_-6px_var(--done)] ring-[1.5px] ring-done/60"
        />
        <h2 className="mx-auto max-w-3xl font-heading text-[clamp(2.3rem,5.2vw,4rem)] leading-[0.98] font-semibold tracking-[-0.05em] text-ink">
          Put your agents <Accent>where you already look.</Accent>
        </h2>
        <p className="mx-auto mt-5 max-w-xl text-[17px] leading-relaxed tracking-[-0.01em] text-slate">
          Notchbee is free and open source. Download the latest release, read the code, file an issue or send a pull
          request.
        </p>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
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
              "h-11 gap-2 rounded-full border-ink/12 bg-canvas px-5 text-[15px] tracking-[-0.01em] text-ink hover:bg-white",
            )}
          >
            <AppleMark className="size-4 -translate-y-px" />
            Download for macOS
            <span className="rounded-full bg-ink/[0.06] px-2 py-0.5 text-[11px] font-medium text-slate">macOS 26+</span>
          </a>
        </div>
        <ul className="mt-12 flex flex-wrap justify-center gap-x-8 gap-y-2 text-[14px] tracking-[-0.01em] text-slate">
          {FACTS.map((fact) => (
            <li key={fact}>{fact}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}

export function Footer() {
  return (
    <footer className="border-t border-hairline px-5 py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-6 text-[13px] text-slate sm:flex-row">
        <a href="#top" className="flex items-center gap-2 text-ink">
          <NotchMark className="h-3.5 w-6" />
          <span className="font-heading text-[15px] font-semibold tracking-[-0.03em]">Notchbee</span>
        </a>
        <nav aria-label="Footer" className="flex items-center gap-5">
          <a href="#how" className="transition hover:text-ink">How it works</a>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="transition hover:text-ink">GitHub</a>
          <a href={`${GITHUB_URL}/issues`} target="_blank" rel="noreferrer" className="transition hover:text-ink">Report an issue</a>
        </nav>
        <p className="text-[13px]">Made for the MacBook notch.</p>
      </div>
    </footer>
  );
}
