import { assertEquals } from "jsr:@std/assert@1";
import {
  heroImageFromHtml,
  largestImageCandidate,
  wikipediaQueries,
  wikipediaThumbnailFromSummary,
} from "./color.ts";

const PAGE = "https://example.org/exhibition/show/";

Deno.test("og:image still wins over everything else", () => {
  const html = `
    <meta property="og:image" content="/social.jpg">
    <script type="application/ld+json">{"image":"https://cdn.example.org/ld.jpg"}</script>
    <img src="/uploads/big-1600x900.jpg">`;
  assertEquals(heroImageFromHtml(html, PAGE), "https://example.org/social.jpg");
});

Deno.test("og:image entities are decoded and a Next.js image proxy is unwrapped (Eventbrite)", () => {
  const html = `<meta property="og:image" content="https://www.eventbrite.co.uk/e/_next/image?url=https%3A%2F%2Fimg.evbuc.com%2Fhttps%253A%252F%252Fcdn.evbuc.com%252Fimages%252F1185684115%252F1304179817133%252F1%252Foriginal.20260529-083700%3Fcrop%3Dfocalpoint%26w%3D940&amp;w=940&amp;q=75" data-next-head=""/>`;
  assertEquals(
    heroImageFromHtml(html, "https://www.eventbrite.co.uk/e/big-finish-day-tickets-1988169832489"),
    "https://img.evbuc.com/https%3A%2F%2Fcdn.evbuc.com%2Fimages%2F1185684115%2F1304179817133%2F1%2Foriginal.20260529-083700?crop=focalpoint&w=940",
  );
});

Deno.test("a relative Next.js proxy resolves against the page", () => {
  const html = `<meta property="og:image" content="/_next/image?url=%2Fposters%2Fshow.jpg&amp;w=1200&amp;q=75">`;
  assertEquals(heroImageFromHtml(html, PAGE), "https://example.org/posters/show.jpg");
});

Deno.test("JSON-LD image is used when there are no social tags (Bermondsey)", () => {
  const html = `
    <script type="application/ld+json">
      {"@context":"https://schema.org","@graph":[
        {"@type":"WebSite","url":"https://example.org/"},
        {"@type":"WebPage","image":{"@type":"ImageObject","url":"https://example.org/wp-content/uploads/hero-image.jpg"}}
      ]}
    </script>
    <img src="/uploads/thumb-300x200.jpg">`;
  assertEquals(
    heroImageFromHtml(html, PAGE),
    "https://example.org/wp-content/uploads/hero-image.jpg",
  );
});

Deno.test("JSON-LD: the event's own image outranks the SEO plugin's logo and page thumb", () => {
  const html = `
    <script type="application/ld+json">
      {"@context":"https://schema.org","@graph":[
        {"@type":"Organization","image":{"@type":"ImageObject","url":"https://example.org/uploads/logo-1-1.webp"}},
        {"@type":"ImageObject","url":"https://example.org/uploads/page-thumb-768x768.webp"},
        {"@type":"WebPage","primaryImageOfPage":{"@id":"#thumb"}}
      ]}
    </script>
    <script type="application/ld+json">
      {"@context":"https://schema.org","@type":"Festival","image":"https://example.org/uploads/hero-image.jpg"}
    </script>`;
  assertEquals(heroImageFromHtml(html, PAGE), "https://example.org/uploads/hero-image.jpg");
});

Deno.test("JSON-LD: with no subject node, a page image still beats the organisation's", () => {
  const html = `
    <script type="application/ld+json">
      {"@graph":[
        {"@type":"Organization","image":"https://example.org/logo.png"},
        {"@type":"WebPage","image":"https://example.org/page.jpg"}
      ]}
    </script>`;
  assertEquals(heroImageFromHtml(html, PAGE), "https://example.org/page.jpg");
});

Deno.test("WordPress size suffix stands in for a missing width attribute (Goldsmiths)", () => {
  const html = `
    <img src="https://example.org/wp-content/uploads/2026/07/CI-ETW-0393-300-scaled.jpg" alt="Painting">
    <img src="https://example.org/wp-content/uploads/2026/09/still-5-800x530.jpg">
    <img src="https://example.org/wp-content/uploads/2026/09/tiny-150x150.jpg">`;
  // -scaled is WordPress's full-size render; it outranks the 800px crop.
  assertEquals(
    heroImageFromHtml(html, PAGE),
    "https://example.org/wp-content/uploads/2026/07/CI-ETW-0393-300-scaled.jpg",
  );
});

Deno.test("srcset: the widest entry names both the size and the file", () => {
  const tag =
    `<img src="/a-480.jpg" srcset="/a-480.jpg 480w, /a-1200.jpg 1200w, /a-800.jpg 800w" alt="">`;
  assertEquals(largestImageCandidate(tag), { src: "/a-1200.jpg", width: 1200 });
});

Deno.test("lazy-loaded images count through data-src / data-srcset", () => {
  const tag =
    `<img class="lazyload" src="data:image/gif;base64,R0lGOD" data-src="/uploads/hero-1400x900.jpg" data-srcset="/uploads/hero-700x450.jpg 700w, /uploads/hero-1400x900.jpg 1400w">`;
  assertEquals(largestImageCandidate(tag), { src: "/uploads/hero-1400x900.jpg", width: 1400 });
});

Deno.test("<picture><source> entries are candidates too", () => {
  const html = `
    <picture>
      <source type="image/webp" srcset="/hero-2000.webp 2000w, /hero-900.webp 900w">
      <img src="/hero.jpg" alt="Hero">
    </picture>`;
  assertEquals(heroImageFromHtml(html, PAGE), "https://example.org/hero-2000.webp");
});

Deno.test("chrome and unsized images are skipped", () => {
  assertEquals(largestImageCandidate(`<img src="/logo-2000x600.png" width="2000">`), null);
  assertEquals(largestImageCandidate(`<img src="/icons/sprite.svg">`), null);
  assertEquals(largestImageCandidate(`<img src="/photo.jpg" alt="no size anywhere">`), null);
  assertEquals(largestImageCandidate(`<img src="/photo-400x300.jpg">`), null);
});

Deno.test("inline style width and ?width= query still work", () => {
  assertEquals(
    largestImageCandidate(`<img src="/p.jpg" style="display:block;width:960px">`),
    { src: "/p.jpg", width: 960 },
  );
  assertEquals(
    largestImageCandidate(`<img src="/cdn/p.jpg?width=1280&q=80">`),
    { src: "/cdn/p.jpg?width=1280&q=80", width: 1280 },
  );
});

Deno.test("density srcset: declared width times the densest entry (Wix)", () => {
  // Verbatim shape from nunheadarttrail.com — width="319" with 1x/2x only.
  const tag =
    `<img fetchpriority="high" sizes="319px" srcSet="https://static.wixstatic.com/media/b3632a_f76d~mv2.jpeg/v1/crop/x_21,y_19,w_759,h_769/fill/w_319,h_323,al_c,q_80,enc_avif,quality_auto/NAT%20Target%20Square.jpeg 1x, https://static.wixstatic.com/media/b3632a_f76d~mv2.jpeg/v1/crop/x_21,y_19,w_759,h_769/fill/w_638,h_646,al_c,q_85,enc_avif,quality_auto/NAT%20Target%20Square.jpeg 2x" src="https://static.wixstatic.com/media/b3632a_f76d~mv2.jpeg/v1/crop/x_21,y_19,w_759,h_769/fill/w_319,h_323,al_c,q_80,enc_avif,quality_auto/NAT%20Target%20Square.jpeg" alt="NAT Target Square.jpeg" width="319" height="323"/>`;
  assertEquals(largestImageCandidate(tag), {
    src:
      "https://static.wixstatic.com/media/b3632a_f76d~mv2.jpeg/v1/crop/x_21,y_19,w_759,h_769/fill/w_638,h_646,al_c,q_85,enc_avif,quality_auto/NAT%20Target%20Square.jpeg",
    width: 638,
  });
  // The 91px Wix logo next to it is still too small at 2x.
  assertEquals(
    largestImageCandidate(
      `<img srcSet="/v1/fill/w_91,h_90/IMG.jpeg 1x, /v1/fill/w_182,h_180/IMG.jpeg 2x" src="/v1/fill/w_91,h_90/IMG.jpeg" width="91">`,
    ),
    null,
  );
});

Deno.test("density srcset without a declared width falls back to the file's URL", () => {
  assertEquals(
    largestImageCandidate(
      `<img src="/v1/fill/w_400,h_300/p.jpg" srcset="/v1/fill/w_400,h_300/p.jpg 1x, /v1/fill/w_800,h_600/p.jpg 2x">`,
    ),
    { src: "/v1/fill/w_800,h_600/p.jpg", width: 800 },
  );
  // Nothing says how wide: still skipped, as before.
  assertEquals(largestImageCandidate(`<img src="/p.jpg" srcset="/p.jpg 1x, /p@2x.jpg 2x">`), null);
});

Deno.test("a real w descriptor beats a density guess", () => {
  const tag =
    `<img width="300" srcset="/a-600.jpg 600w, /a-900.jpg 3x" src="/a.jpg">`;
  assertEquals(largestImageCandidate(tag), { src: "/a-600.jpg", width: 600 });
});

Deno.test("Wix transform paths name the width when nothing else does", () => {
  assertEquals(
    largestImageCandidate(`<img src="https://static.wixstatic.com/media/x~mv2.jpg/v1/fill/w_1200,h_800,al_c/x.jpg">`),
    { src: "https://static.wixstatic.com/media/x~mv2.jpg/v1/fill/w_1200,h_800,al_c/x.jpg", width: 1200 },
  );
  assertEquals(
    largestImageCandidate(`<img src="https://static.wixstatic.com/media/x~mv2.jpg/v1/fit/w_320,h_200/x.jpg">`),
    null,
  );
});

Deno.test("Wikipedia queries skip short and placeholder names", () => {
  assertEquals(wikipediaQueries({ title: "Kin", venue: null }), []);
  assertEquals(wikipediaQueries({ title: "New item", venue: "X" }), []);
  assertEquals(
    wikipediaQueries({ title: "Nick Cave at All Points East", venue: "All Points East" }),
    ["All Points East", "Nick Cave at All Points East"],
  );
});

Deno.test("Wikipedia summary: keep a matching original image, drop disambiguation", () => {
  const page = {
    type: "standard",
    title: "All Points East",
    originalimage: { source: "https://upload.wikimedia.org/wiki/ape.jpg" },
  };
  assertEquals(
    wikipediaThumbnailFromSummary(page, "All Points East"),
    "https://upload.wikimedia.org/wiki/ape.jpg",
  );
  assertEquals(
    wikipediaThumbnailFromSummary({ ...page, type: "disambiguation" }, "All Points East"),
    null,
  );
  assertEquals(
    wikipediaThumbnailFromSummary(page, "Somewhere Else Festival"),
    null,
  );
});
