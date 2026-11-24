// One save, typed, linked or screenshotted, made into a card: read what it
// links to (read.ts), ask the model (ask.ts), then look up where it is and
// what it looks like (lookup.ts).

import { askForCard, type ParsedCard, type ParseRun, VagueInputError } from "./ask.ts";
import { resolveMapsLink } from "./geo.ts";
import { type Home, LONDON } from "./home.ts";
import { colour, earlyColour, hoursPlace, inTimeFor, isAnchored, locate, picture } from "./lookup.ts";
import {
  cleanLink,
  fetchPage,
  firstUrl,
  isFetchable,
  jsonLdEvents,
  landingUrl,
  ldClosing,
  linkKey,
  looksBlocked,
  ownPage,
  type Page,
} from "./read.ts";
import { fetchImageBase64, fetchSocialPost, socialPlatform, SocialUnreadableError } from "./social.ts";

export interface ExtractInput {
  text?: string;          // pasted text, forwarded message, or a bare URL
  image_base64?: string;  // screenshot (e.g. of an Instagram post)
  image_media_type?: string;
}

/// The model's fields, before the lookups after it (address, pin, photo,
/// colour) are done. Nothing here changes by the time the card is final,
/// except an end date the page's own listing can still fill in. `link`
/// is the page the model found for a typed name or a screenshot, not yet
/// checked: the phone can start on its picture while the lookups run.
export type EarlyCard =
  & Pick<
    ParsedCard,
    "kind" | "title" | "summary" | "venue" | "area" | "category" | "price" | "starts_on" | "ends_on" | "showings"
  >
  & { link: string | null };

export async function extractCard(
  input: ExtractInput,
  home: Home = LONDON,
  /** The link's page, already read (or found unreadable) by the caller. */
  read?: { page: Page | null },
  /** Called once the model has answered, while the lookups run. */
  onEarly?: (early: EarlyCard) => void,
  run: ParseRun = {},
): Promise<
  ParsedCard & {
    url: string | null;
    source: string;
    lat: number | null;
    lng: number | null;
    color: string | null;
    image_url: string | null;
    /** The Google place its opening hours come from. */
    place_id: string | null;
    /** The save's own page walled this server off, so its photo came from
     * somewhere else; the phone can often read the page's own. */
    page_unread: boolean;
  }
> {
  const started = Date.now();
  const left = () => (run.deadline ?? Infinity) - Date.now();
  const inTime = inTimeFor(run);

  const text = (input.text ?? "").trim();
  const url = text ? firstUrl(text) : null;
  // Google Maps links: never fetch the page (it's huge, JS-only junk); the
  // URL itself names the place and pins its coordinates.
  const mapsLink = url ? await resolveMapsLink(url) : null;
  let page: Page | null = null;
  if (url && !mapsLink && isFetchable(url)) {
    page = read ? read.page : await fetchPage(url);
    if (page && looksBlocked(page.text)) page = null;
  }
  const pageText = page?.text ?? null;

  // Social links (Instagram, TikTok, Facebook) have no readable page, but
  // their caption and cover are reachable without a login — see social.ts.
  // The cover is fetched as bytes for the model to read the on-screen text;
  // its URL is signed and expiring, so it is never stored as the thumbnail.
  const social = url && !mapsLink ? socialPlatform(url) : null;
  const post = social ? await fetchSocialPost(url!) : null;
  const cover = post?.image && !input.image_base64
    ? await fetchImageBase64(post.image)
    : null;
  // The user's own words beyond the bare link — a name they typed after
  // it, or a caption the app fetched on-device when this server couldn't.
  const ownWords = url ? text.replace(url, "").trim() : text;
  if (social && !post && !ownWords && !input.image_base64) {
    // Nothing from the platform, nothing from the user: asking beats a
    // card invented from a URL slug.
    throw new SocialUnreadableError(social);
  }

  // A link we couldn't read: let the model search the web for the real
  // details instead of guessing from the URL slug alone. Every maps link
  // searches too — a pin carries no page to read, so the official website
  // (and with it the thumbnail photo) can only come from search. Bare
  // typed names and screenshots search for the same reason: without a
  // page there is no other route to verified details or a venue photo.
  // Social posts always search: a caption names a place, the web confirms
  // it and finds the official site.
  const useWebSearch =
    Boolean(url && !mapsLink && !pageText) ||
    Boolean(mapsLink) ||
    Boolean(!url && (text || input.image_base64));

  const colorPromise = earlyColour(input.image_base64, cover?.base64 ?? null, page);

  // A share link's own path names nothing; where it lands often does.
  const landing = url && !mapsLink && !pageText && !social
    ? await inTime("landing", () => landingUrl(url), null)
    : null;

  const image = input.image_base64
    ? { media_type: input.image_media_type ?? "image/jpeg", data: input.image_base64 }
    : cover
    ? { media_type: cover.mediaType, data: cover.base64 }
    : null;

  run.route = input.image_base64 ? "image" : post ? "social" : mapsLink ? "maps" : pageText ? "page" : "search";
  run.read_ms = Date.now() - started;
  // Whatever is left past the model call goes to the lookups after it,
  // which can each be skipped; the call itself can't.
  const { card, link: proposedLink, sources } = await askForCard(
    {
      text,
      url,
      pageText,
      post,
      cover: Boolean(cover),
      mapsLink,
      landing,
      screenshot: Boolean(input.image_base64),
      search: useWebSearch,
    },
    image,
    home,
    run,
    left() - 6_000,
  );
  const modelDone = Date.now();

  const early: EarlyCard = {
    kind: card.kind,
    title: card.title,
    summary: card.summary,
    venue: card.venue,
    area: card.area,
    category: card.category,
    price: card.price,
    starts_on: card.starts_on,
    ends_on: card.ends_on,
    showings: card.showings,
    link: url ? null : proposedLink ?? null,
  };
  const sendEarly = () => {
    run.early_ms = Date.now() - started;
    onEarly?.(early);
  };
  // The pin in a Maps URL is exact — trust it over geocoding the name.
  const pin = mapsLink && mapsLink.lat !== null && mapsLink.lng !== null
    ? { lat: mapsLink.lat, lng: mapsLink.lng }
    : null;
  // A card that may yet be refused for having nothing to stand on waits
  // for the lookups that decide it, so the phone never shows fields and
  // then takes them back.
  const standing = isAnchored(card, { url, coords: pin });
  if (standing) sendEarly();

  const seen = new Set<string>();
  for (const source of sources) {
    const key = linkKey(source);
    if (key) seen.add(key);
  }

  const { coords, google } = await locate(card, home, pin, mapsLink?.name ?? null, inTime);

  // A card with nothing to stand on is not a save. The model's own verdict
  // came first, before the lookups; this catches the times it said
  // "specific" but still produced a spot with no link, no site, no pin and
  // no address.
  if (!isAnchored(card, { url, coords })) {
    throw new VagueInputError();
  }
  if (!standing) sendEarly();

  // Where its opening hours come from, looked up while the photo is.
  const placeFound = hoursPlace(card, home, coords, google, inTime);

  // The save's link: a pasted one as is; for typed names and screenshots,
  // the thing's own page, so the save opens somewhere and "Fetch again"
  // reads a page instead of searching from scratch.
  const eventDates = card.kind === "event"
    ? [card.starts_on, card.ends_on].filter((d): d is string => Boolean(d))
    : [];
  const own = !url && proposedLink
    ? await inTime("link", () => ownPage(proposedLink, seen, eventDates), null)
    : null;
  const savedUrl = url ?? own?.url ?? null;
  card.ends_on ??= ldClosing(page?.events ?? (own?.html ? jsonLdEvents(own.html) : []), card);

  const photo = await picture(card, { url, page, own, proposedLink }, google, inTime);
  const color = await colour(colorPromise, photo, inTime);
  const placeId = (await placeFound)?.id ?? null;

  const done = Date.now();
  run.lookups_ms = done - modelDone;
  console.log("parse timing", JSON.stringify({
    route: run.route,
    searches: run.searches ?? 0,
    output_tokens: run.output_tokens ?? null,
    read_ms: run.read_ms,
    model_ms: run.model_ms,
    lookups_ms: run.lookups_ms,
    total_ms: done - started,
    ...(run.skipped?.length ? { skipped: run.skipped } : {}),
  }));

  return {
    ...card,
    // The model writes these, so a page's injected text could ask for any scheme.
    booking_url: card.booking_url ? cleanLink(card.booking_url) : null,
    website: card.website ? cleanLink(card.website) : null,
    url: savedUrl,
    source: input.image_base64 ? "image" : url ? "link" : "text",
    lat: coords?.lat ?? null,
    lng: coords?.lng ?? null,
    color,
    image_url: photo.imageUrl,
    place_id: placeId,
    page_unread: Boolean(own && own.html === null),
  };
}
