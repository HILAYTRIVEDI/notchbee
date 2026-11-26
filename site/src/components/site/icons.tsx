export function GitHubMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className={className} fill="currentColor">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

export function AppleMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 17 20" aria-hidden className={className} fill="currentColor">
      <path d="M14.04 10.6c-.02-2.35 1.92-3.48 2-3.54-1.09-1.6-2.79-1.82-3.4-1.84-1.45-.15-2.82.85-3.56.85-.73 0-1.87-.83-3.07-.81-1.58.02-3.04.92-3.85 2.33-1.64 2.85-.42 7.06 1.18 9.37.78 1.13 1.71 2.4 2.93 2.35 1.18-.05 1.62-.76 3.04-.76 1.42 0 1.82.76 3.06.74 1.27-.02 2.07-1.15 2.84-2.29.9-1.31 1.27-2.58 1.29-2.65-.03-.01-2.47-.95-2.47-3.76zM11.7 3.7c.65-.79 1.09-1.88.97-2.97-.94.04-2.07.62-2.74 1.41-.6.7-1.13 1.81-.99 2.88 1.05.08 2.12-.53 2.76-1.32z" />
    </svg>
  );
}

/** The product mark: a notch with a glowing lower edge. */
export function NotchMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 28 16" aria-hidden className={className}>
      <defs>
        <linearGradient id="mark-comet" x1="0" x2="1">
          <stop offset="0" stopColor="#73a8fd" />
          <stop offset="1" stopColor="#9e73ff" />
        </linearGradient>
      </defs>
      <path d="M1 1.5 C3 1.5 4 2.5 4 4.5 V9.5 Q4 14.5 9 14.5 H19 Q24 14.5 24 9.5 V4.5 C24 2.5 25 1.5 27 1.5 Z" fill="#000" />
      <path d="M4 4.5 V9.5 Q4 14.5 9 14.5 H19 Q24 14.5 24 9.5 V4.5" fill="none" stroke="url(#mark-comet)" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  );
}
