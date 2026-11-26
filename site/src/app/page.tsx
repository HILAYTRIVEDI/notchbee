import { Closing, Footer } from "@/components/site/closing";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
import { NotchNav } from "@/components/site/notch-nav";
import { TryIt } from "@/components/site/try-it";

export default function Home() {
  return (
    <>
      <NotchNav />
      <main className="flex-1">
        <Hero />
        <TryIt />
        <Features />
        <Closing />
      </main>
      <Footer />
    </>
  );
}
