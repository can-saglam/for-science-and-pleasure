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
