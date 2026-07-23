import { useMemo } from "react";
import { CircleMarker, MapContainer, Popup, TileLayer } from "react-leaflet";
import { latLngBounds } from "leaflet";
import "leaflet/dist/leaflet.css";
import type { Item } from "@/lib/types";
import { googleMapsUrl } from "@/lib/api";
import { ArrowUpRight } from "lucide-react";

// Monochrome CARTO basemap (keyless). Google Maps stays the destination for
// every pin — embedding Google's own tiles needs a billed Maps API key.
const TILES = "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";
const ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/attributions">CARTO</a>';

const LONDON: [number, number] = [51.5074, -0.1276];

export function MapWeek({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
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
      <div className="overflow-hidden rounded-xl border">
        <MapContainer
          {...(bounds
            ? { bounds, boundsOptions: { padding: [40, 40] } }
            : {
                center: pins[0] ? [pins[0].lat!, pins[0].lng!] : LONDON,
                zoom: 13,
              })}
          style={{ height: "55dvh", width: "100%" }}
          scrollWheelZoom
        >
          <TileLayer url={TILES} attribution={ATTRIBUTION} />
          {pins.map((i) => (
            <CircleMarker
              key={i.id}
              center={[i.lat!, i.lng!]}
              radius={8}
              pathOptions={{
                color: "#111111",
                weight: 2,
                fillColor: i.kind === "event" ? "#111111" : "#ffffff",
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
                  <div className="text-xs text-neutral-500">
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
