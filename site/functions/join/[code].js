// An invite's page with the inviter in it. Chats read the page's title
// without running its script, so without this every invite previews as the
// same "Join me on Can We Go?". The invite also rides along in the page.

import { invite, names } from "../../lib/invite.js";

const content = (value) => ({ element: (el) => el.setAttribute("content", value) });

function words({ status, from, members }) {
  if (status === "expired") {
    return {
      title: "This invite has expired",
      description: from ? `Ask ${from} for a new one.` : "Ask for a new one.",
    };
  }
  const who = names(members.map((m) => m.name)) || from;
  return {
    title: from ? `${from} invited you to Can We Go?` : "You’re invited to Can We Go?",
    description: `${who ? `Join ${who}’s` : "Share a"} list of the exhibitions, gigs and restaurants you’ll go to together.`,
  };
}

export async function onRequestGet({ request, params, env }) {
  const page = await env.ASSETS.fetch(new URL("/join/", request.url));
  const found = await invite(params.code, {
    visitor: request.headers.get("cf-connecting-ip"),
    siteKey: env.SITE_LOOKUP_SECRET,
  });
  if (!found) return page;
  const { title, description } = words(found);

  const res = new HTMLRewriter()
    .on("title", { element: (el) => el.setInnerContent(title) })
    .on('meta[property="og:title"]', content(title))
    .on('meta[property="og:description"]', content(description))
    .on('meta[name="description"]', content(description))
    .on("body", { element: (el) => el.setAttribute("data-preload", JSON.stringify(found)) })
    .transform(page);
  const out = new Response(res.body, res);
  out.headers.set("Cache-Control", "public, max-age=60");
  return out;
}
