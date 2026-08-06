import { useEffect, useMemo, useRef, useState } from "react";
import {
  Circle,
  CircleMarker,
  MapContainer,
  Popup,
  TileLayer,
  useMap,
} from "react-leaflet";
import { latLngBounds } from "leaflet";
import "leaflet/dist/leaflet.css";
import { toast } from "sonner";
import type { Item } from "@/lib/types";
import { googleMapsUrl } from "@/lib/api";
import { useIsDark } from "@/lib/theme";
import { ArrowUpRight, LocateFixed } from "lucide-react";
import { cn } from "@/lib/utils";

// Monochrome CARTO basemaps (keyless). Google Maps stays the destination for
// every pin — embedding Google's own tiles needs a billed Maps API key.
const TILES_LIGHT =
  "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";
const TILES_DARK =
  "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
const ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/attributions">CARTO</a>';

const LONDON: [number, number] = [51.5074, -0.1276];

interface Fix {
  lat: number;
  lng: number;
  accuracy: number;
}

// Blue dot + accuracy ring, flying to the first fix only — after that the
// dot follows you quietly so panning around isn't fought by the map.
// (Remounts per tracking session, so the ref resets with it.)
function SelfMarker({ fix }: { fix: Fix }) {
  const map = useMap();
  const flown = useRef(false);

  useEffect(() => {
    if (flown.current) return;
    flown.current = true;
    map.flyTo([fix.lat, fix.lng], Math.max(map.getZoom(), 15));
  }, [map, fix]);

  return (
    <>
      {fix.accuracy > 25 && (
        <Circle
          center={[fix.lat, fix.lng]}
          radius={fix.accuracy}
          pathOptions={{
            color: "#3b82f6",
            weight: 1,
            opacity: 0.4,
            fillColor: "#3b82f6",
            fillOpacity: 0.12,
          }}
        />
      )}
      <CircleMarker
        center={[fix.lat, fix.lng]}
        radius={7}
        pathOptions={{
          color: "#ffffff",
          weight: 3,
          fillColor: "#3b82f6",
          fillOpacity: 1,
        }}
      />
    </>
  );
}

function MapInteraction({ enabled }: { enabled: boolean }) {
  const map = useMap();

  useEffect(() => {
    const handlers = [
      map.dragging,
      map.touchZoom,
      map.doubleClickZoom,
      map.boxZoom,
      map.keyboard,
      map.scrollWheelZoom,
    ];
    for (const handler of handlers) {
      if (enabled) handler.enable();
      else handler.disable();
    }
  }, [enabled, map]);

  return null;
}

export function MapWeek({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const dark = useIsDark();
  const [touchDevice] = useState(() =>
    window.matchMedia("(pointer: coarse)").matches,
  );
  const [interactive, setInteractive] = useState(() => !touchDevice);
  const [tracking, setTracking] = useState(false);
  const [fix, setFix] = useState<Fix | null>(null);

  useEffect(() => {
    if (!tracking) {
      setFix(null);
      return;
    }
    if (!navigator.geolocation) {
      toast.error("Location isn't available on this device.");
      setTracking(false);
      return;
    }
    const watchId = navigator.geolocation.watchPosition(
      (pos) =>
        setFix({
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          accuracy: pos.coords.accuracy,
        }),
      (err) => {
        toast.error(
          err.code === err.PERMISSION_DENIED
            ? "Location permission was denied — allow it in your phone's settings."
            : "Couldn't get your location.",
        );
        setTracking(false);
      },
      { enableHighAccuracy: true, maximumAge: 5_000, timeout: 20_000 },
    );
    return () => navigator.geolocation.clearWatch(watchId);
  }, [tracking]);

  const pins = useMemo(
    () => items.filter((i) => i.lat != null && i.lng != null),
    [items],
  );
  const missing = items.length - pins.length;

  const bounds = useMemo(() => {
    if (pins.length < 2) return null;
    return latLngBounds(pins.map((p) => [p.lat!, p.lng!] as [number, number]));
  }, [pins]);

  return (
    <div className="space-y-2">
      <div className="map-with-fab relative z-0 h-[55dvh] overflow-hidden rounded-xl border md:h-[65dvh]">
        <MapContainer
          {...(bounds
            ? { bounds, boundsOptions: { padding: [40, 40] } }
            : {
                center: pins[0] ? [pins[0].lat!, pins[0].lng!] : LONDON,
                zoom: 13,
              })}
          style={{ height: "100%", width: "100%" }}
          dragging={interactive}
          touchZoom={interactive}
          doubleClickZoom={interactive}
          scrollWheelZoom={interactive}
        >
          <MapInteraction enabled={interactive} />
          {/* key forces a fresh layer when the theme flips */}
          <TileLayer
            key={dark ? "dark" : "light"}
            url={dark ? TILES_DARK : TILES_LIGHT}
            attribution={ATTRIBUTION}
          />
          {fix && <SelfMarker fix={fix} />}
          {pins.map((i) => (
            <CircleMarker
              key={i.id}
              center={[i.lat!, i.lng!]}
              radius={8}
              pathOptions={{
                color: dark ? "#e5e5e5" : "#111111",
                weight: 2,
                fillColor:
                  i.kind === "event"
                    ? dark
                      ? "#e5e5e5"
                      : "#111111"
                    : dark
                      ? "#171717"
                      : "#ffffff",
                fillOpacity: 1,
              }}
            >
              <Popup>
                <div className="space-y-1">
                  <button
                    onClick={() => onSelect(i)}
                    className="text-left text-sm font-semibold underline-offset-4 hover:underline"
                  >
                    {i.title}
                  </button>
                  <div className="text-xs text-muted-foreground">
                    {[i.venue !== i.title ? i.venue : null, i.area]
                      .filter(Boolean)
                      .join(" · ")}
                  </div>
                  <a
                    href={googleMapsUrl(i)}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1 text-xs underline underline-offset-2"
                  >
                    Google Maps <ArrowUpRight className="size-3" />
                  </a>
                </div>
              </Popup>
            </CircleMarker>
          ))}
        </MapContainer>
        <button
          type="button"
          aria-label={tracking ? "Stop showing my location" : "Show my location"}
          onClick={() => {
            setTracking((t) => !t);
            // Following yourself on a frozen map is pointless.
            if (!tracking) setInteractive(true);
          }}
          className={cn(
            "absolute bottom-3 right-2 z-[1001] flex size-11 items-center justify-center rounded-full bg-background/95 shadow-sm ring-1 ring-foreground/15 backdrop-blur",
            tracking ? "text-blue-500" : "text-foreground",
          )}
        >
          <LocateFixed className="size-5" />
        </button>
        {touchDevice && !interactive && (
          <button
            type="button"
            onClick={() => setInteractive(true)}
            className="absolute inset-0 z-[1000] flex touch-pan-y items-center justify-center bg-transparent"
          >
            <span className="rounded-full bg-background/95 px-4 py-2 text-sm font-medium shadow-sm ring-1 ring-foreground/15 backdrop-blur">
              Tap to explore map
            </span>
          </button>
        )}
        {touchDevice && interactive && (
          <button
            type="button"
            onClick={() => setInteractive(false)}
            className="absolute right-2 top-2 z-[1000] min-h-11 rounded-full bg-background/95 px-4 text-sm font-medium shadow-sm ring-1 ring-foreground/15 backdrop-blur"
          >
            Done
          </button>
        )}
      </div>
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <div className="flex items-center gap-3">
          <span className="inline-flex items-center gap-1.5">
            <span className="size-2.5 rounded-full bg-foreground" /> events
          </span>
          <span className="inline-flex items-center gap-1.5">
            <span className="size-2.5 rounded-full border-2 border-foreground bg-background" /> places
          </span>
        </div>
        {missing > 0 && <span>{missing} without a location</span>}
      </div>
    </div>
  );
}
