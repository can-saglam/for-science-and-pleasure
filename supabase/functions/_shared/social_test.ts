import { assertEquals } from "jsr:@std/assert";
import {
  instagramPostUrl,
  isTikTokShortLink,
  parseInstagramDescription,
  socialPlatform,
} from "./social.ts";

Deno.test("socialPlatform recognises the three hosts and their subdomains", () => {
  assertEquals(socialPlatform("https://www.instagram.com/p/DJHls9spGFY/"), "instagram");
  assertEquals(socialPlatform("https://vm.tiktok.com/ZGJ8abcde/"), "tiktok");
  assertEquals(socialPlatform("https://www.tiktok.com/@emma/video/7608575751356468502"), "tiktok");
  assertEquals(socialPlatform("https://m.facebook.com/events/123/"), "facebook");
  assertEquals(socialPlatform("https://fb.watch/abc/"), "facebook");
  assertEquals(socialPlatform("https://www.barbican.org.uk/whats-on"), null);
  assertEquals(socialPlatform("not a url"), null);
});

Deno.test("tiktok short links", () => {
  assertEquals(isTikTokShortLink("https://vm.tiktok.com/ZGJ8abcde/"), true);
  assertEquals(isTikTokShortLink("https://vt.tiktok.com/ZS123/"), true);
  assertEquals(isTikTokShortLink("https://www.tiktok.com/t/ZT8abc/"), true);
  assertEquals(isTikTokShortLink("https://www.tiktok.com/@emma/video/760857575"), false);
});

Deno.test("instagram post URL canonicalises p / reel / reels / tv and rejects profiles", () => {
  assertEquals(
    instagramPostUrl("https://www.instagram.com/reel/DJHls9spGFY/?igsh=abc"),
    "https://www.instagram.com/reel/DJHls9spGFY/",
  );
  assertEquals(
    instagramPostUrl("https://instagram.com/p/DaVAq6vCI1-/"),
    "https://www.instagram.com/p/DaVAq6vCI1-/",
  );
  assertEquals(
    instagramPostUrl("https://www.instagram.com/dezeen/reels/DaVAq6vCI1-/"),
    "https://www.instagram.com/reel/DaVAq6vCI1-/",
  );
  assertEquals(instagramPostUrl("https://www.instagram.com/londonradicalbookfair/"), null);
  assertEquals(instagramPostUrl("https://www.instagram.com/explore/tags/london/"), null);
});

Deno.test("instagram og:description → author + caption", () => {
  const parsed = parseInstagramDescription(
    '3,886 likes, 22 comments - dezeen on July 3, 2026: "Speculative architect and artist Liam Young has opened an immersive exhibition at London\'s Barbican Centre."',
  );
  assertEquals(parsed?.author, "dezeen");
  assertEquals(
    parsed?.caption,
    "Speculative architect and artist Liam Young has opened an immersive exhibition at London's Barbican Centre.",
  );
});

Deno.test("instagram profile description is not a post", () => {
  assertEquals(
    parseInstagramDescription(
      "579 Followers, 63 Following, 18 Posts - See Instagram photos and videos from London Radical Bookfair (@londonradicalbookfair)",
    ),
    null,
  );
});

Deno.test("instagram description in an unknown shape keeps the text", () => {
  const parsed = parseInstagramDescription("Some caption without the usual prefix");
  assertEquals(parsed?.author, null);
  assertEquals(parsed?.caption, "Some caption without the usual prefix");
});
