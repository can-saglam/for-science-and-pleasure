import { useEffect, useState } from "react";
import { Bell, BellOff, Loader2 } from "lucide-react";
import {
  disablePush,
  enablePush,
  getPushStatus,
  type PushStatus,
} from "@/lib/push";
import { Button } from "@/components/ui/button";

export function NotificationSettings() {
  const [status, setStatus] = useState<PushStatus>("off");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getPushStatus().then(setStatus).catch((reason) => setError(String(reason)));
  }, []);

  async function toggle() {
    setBusy(true);
    setError(null);
    try {
      if (status === "subscribed") {
        await disablePush();
      } else {
        await enablePush();
      }
      setStatus(await getPushStatus());
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
      setStatus(await getPushStatus().catch(() => status));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-3 rounded-xl border p-4">
      <div>
        <h3 className="font-medium">Weekly heads-up</h3>
        <p className="mt-1 text-sm text-muted-foreground">
          A short note at 10am every Tuesday about what is opening, ending, and
          worth pairing this week.
        </p>
      </div>

      {status === "unsupported" && (
        <p className="text-sm text-muted-foreground">
          On iPhone, install Can We Go? to your Home Screen and open it there
          to enable notifications.
        </p>
      )}
      {status === "denied" && (
        <p className="text-sm text-muted-foreground">
          Notifications are blocked. Re-enable them for Can We Go? in your
          device settings.
        </p>
      )}
      {status === "subscribed" && (
        <p className="flex items-center gap-2 text-sm">
          <Bell className="size-4" />
          Weekly notifications are on for this device.
        </p>
      )}
      {status === "off" && (
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          <BellOff className="size-4" />
          Weekly notifications are off on this device.
        </p>
      )}

      {error && <p className="text-sm text-destructive">{error}</p>}

      {(status === "off" || status === "subscribed") && (
        <Button
          className="w-full"
          variant={status === "subscribed" ? "outline" : "default"}
          disabled={busy}
          onClick={toggle}
        >
          {busy && <Loader2 className="animate-spin" />}
          {status === "subscribed"
            ? "Turn off on this device"
            : "Enable weekly notifications"}
        </Button>
      )}
    </section>
  );
}
