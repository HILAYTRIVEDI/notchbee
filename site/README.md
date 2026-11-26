# Notchbee site

The landing page: Next.js (App Router), Tailwind CSS, shadcn/ui and Motion.

```sh
npm install
npm run dev     # http://localhost:3000
npm run build
```

- `src/components/site/notch-demo.tsx` is the interactive hero: a working miniature of the notch at the app's real
  point sizes (hover, start a session, approve, finish, view, commit and push).
- `src/components/site/notch-nav.tsx` is the frosted-glass, notch-shaped navigation with the activity glow.
- `src/components/site/features.tsx` lists the ten features; `notch-video.tsx` plays each recording with the
  hardware notch drawn back in and zooms in on the part that matters.
- `public/media/` holds the recordings (H.264 MP4 and a poster frame each) and the wallpaper crop the demo sits on.
  They were captured from the app's Fake backend over the macOS Tahoe Light wallpaper, so they contain no real
  projects.
- The GitHub link lives in `src/components/site/site-links.ts`. The Download buttons are placeholders marked
  "Soon" until a signed build is published.
