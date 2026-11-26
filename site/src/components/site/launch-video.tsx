/** The 21-second launch film, with sound, in the page's bezel. It waits for a click rather than autoplaying. */
export function LaunchVideo() {
  return (
    <div className="mx-auto max-w-6xl rounded-[22px] bg-[#0d0e12] p-[5px] shadow-[0_1px_0_0_rgba(255,255,255,0.08)_inset,0_40px_80px_-40px_rgba(10,12,20,0.55),0_12px_30px_-18px_rgba(10,12,20,0.4)]">
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
  );
}
