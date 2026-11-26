import { Closing, Footer } from "@/components/site/closing";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
import { LaunchVideo } from "@/components/site/launch-video";
import { NotchNav } from "@/components/site/notch-nav";

export default function Home() {
  return (
    <>
      <NotchNav />
      <main className="flex-1">
        <Hero />
        <LaunchVideo />
        <Features />
        <Closing />
      </main>
      <Footer />
    </>
  );
}
