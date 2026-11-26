"use client";

import { useRef, useState } from "react";
import { Play } from "lucide-react";

/**
 * The 21-second launch film, with sound, in the page's bezel. It waits for a click rather than autoplaying:
 * a large play button sits over the poster, and the native controls appear once it has started.
 */
export function LaunchVideo() {
  const ref = useRef<HTMLVideoElement>(null);
  const [started, setStarted] = useState(false);
  const [playing, setPlaying] = useState(false);

  const toggle = () => {
    const video = ref.current;
    if (!video) return;
    if (video.paused || video.ended) video.play().catch(() => {});
    else video.pause();
  };

  return (
    <div className="mx-auto max-w-6xl rounded-[22px] bg-[#0d0e12] p-[5px] shadow-[0_1px_0_0_rgba(255,255,255,0.08)_inset,0_40px_80px_-40px_rgba(10,12,20,0.55),0_12px_30px_-18px_rgba(10,12,20,0.4)]">
      <div className="relative overflow-hidden rounded-[17px] bg-black">
        <video
          ref={ref}
          className="block aspect-video w-full cursor-pointer"
          src="/media/launch.mp4"
          poster="/media/launch.jpg"
          controls={started}
          playsInline
          preload="none"
          aria-label="Notchbee launch video: starting a session, approving a command, the done card and committing from the notch."
          onClick={started ? undefined : toggle}
          onPlay={() => {
            setStarted(true);
            setPlaying(true);
          }}
          onPause={() => setPlaying(false)}
          onEnded={() => setPlaying(false)}
        />
        {!playing && (
          <button
            type="button"
            onClick={toggle}
            aria-label="Play the launch video"
            className={`group absolute inset-x-0 top-0 flex items-end justify-center pb-[5%] sm:pb-[13%] ${started ? "bottom-16" : "bottom-0"}`}
          >
            <span className="flex items-center gap-2 rounded-full bg-ink py-1 pr-3.5 pl-1 text-[13px] sm:gap-2.5 sm:py-2.5 sm:pr-5 sm:pl-2 font-medium tracking-[-0.01em] text-white shadow-[0_20px_40px_-12px_rgba(10,12,20,0.6)] transition group-hover:scale-105 sm:text-[16px]">
              <span className="flex size-6 items-center justify-center rounded-full bg-white text-ink sm:size-9">
                <Play className="ml-0.5 size-3 fill-current sm:size-4" />
              </span>
              {started ? "Resume" : "Watch the video"}
              <span className="text-white/55">0:21</span>
            </span>
          </button>
        )}
      </div>
    </div>
  );
}
