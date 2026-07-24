import { useState } from "react";
import { addDays, format, nextSaturday } from "date-fns";
import { suggestPlans } from "@/lib/api";
import type { DayPlan } from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
  DrawerTrigger,
} from "@/components/ui/drawer";
import { toast } from "sonner";
import { Wand2 } from "lucide-react";

export function PlanDay() {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(() =>
    format(nextSaturday(addDays(new Date(), -1)), "yyyy-MM-dd"),
  );
  const [busy, setBusy] = useState(false);
  const [plans, setPlans] = useState<DayPlan[] | null>(null);

  async function generate() {
    setBusy(true);
    setPlans(null);
    try {
      setPlans(await suggestPlans(date));
    } catch (e) {
      toast.error(String(e instanceof Error ? e.message : e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Drawer open={open} onOpenChange={setOpen}>
      <DrawerTrigger asChild>
        <Button variant="outline" className="w-full">
          <Wand2 /> Free on a day? Get plan ideas
        </Button>
      </DrawerTrigger>
      <DrawerContent className="max-h-[92dvh]">
        <div className="mx-auto w-full min-w-0 max-w-lg overscroll-contain overflow-x-hidden overflow-y-auto px-4 pb-8 scroll-pb-[40dvh]">
          <DrawerHeader className="px-0">
            <DrawerTitle className="text-left">Plan a day</DrawerTitle>
          </DrawerHeader>

          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label>Which day?</Label>
              <Input
                type="date"
                value={date}
                onChange={(e) => setDate(e.target.value)}
              />
            </div>
            <Button className="w-full" disabled={busy || !date} onClick={generate}>
              <Wand2 /> {busy ? "Thinking…" : "Suggest plans from our list"}
            </Button>

            {plans && plans.length === 0 && (
              <p className="pt-4 text-center text-sm text-muted-foreground">
                Couldn't put a plan together — save more things first.
              </p>
            )}

            {plans?.map((plan, idx) => (
              <div
                key={idx}
                className="space-y-2 overflow-hidden rounded-xl border bg-card p-4 [overflow-wrap:anywhere]"
              >
                <div className="font-heading font-semibold">{plan.title}</div>
                <p className="text-sm text-muted-foreground">{plan.why}</p>
                <ol className="space-y-1 text-sm">
                  {plan.steps.map((s, i) => (
                    <li key={i} className="flex gap-2">
                      <span className="text-muted-foreground">{i + 1}.</span>
                      <span>{s}</span>
                    </li>
                  ))}
                </ol>
              </div>
            ))}
          </div>
        </div>
      </DrawerContent>
    </Drawer>
  );
}
