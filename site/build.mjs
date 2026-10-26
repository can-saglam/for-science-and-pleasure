// Builds site/src into site/dist. No dependencies: `node site/build.mjs`.
//
// - `<!-- include path -->` pulls in a file from src/ (partials, inline SVG).
// - `{{name}}` fills from site.config.json plus a few derived values; an
//   unknown name fails the build rather than shipping braces.
// - The privacy policy and terms are rendered from the app bundle's own
//   markdown, so the site and the app can never disagree.

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const src = join(here, "src");
const dist = join(here, "dist");
const config = JSON.parse(readFileSync(join(here, "site.config.json"), "utf8"));

const storeUrl = config.appStoreId ? `https://apps.apple.com/app/id${config.appStoreId}` : "";
const vars = {
  ...config,
  appStoreUrl: storeUrl || "#download",
  // For pages other than home, where there's no #download to land on.
  getAppUrl: storeUrl || "/#download",
  smartBanner: config.appStoreId ? `<meta name="apple-itunes-app" content="app-id=${config.appStoreId}">` : "",
  year: String(new Date().getFullYear()),
};

const markdownPages = [
  { slug: "privacy", file: join(root, "ios/CanWeGo/Resources/PRIVACY.md"), title: "Privacy Policy" },
  { slug: "terms", file: join(root, "ios/CanWeGo/Resources/TERMS.md"), title: "Terms of Use" },
  { slug: "support", file: join(src, "support.md"), title: "Support" },
];

function render(text, extra = {}, from = "") {
  const scope = { ...vars, ...extra };
  const included = text.replace(/<!--\s*include\s+(\S+)\s*-->/g, (_, path) =>
    render(readFileSync(join(src, path), "utf8"), extra, path).trim(),
  );
  return included.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, name) => {
    if (!(name in scope)) throw new Error(`${from || "page"}: unknown {{${name}}}`);
    return scope[name];
  });
}

// Cloudflare keeps scripts and stylesheets for hours, so each reference to
// one carries a hash of what it serves: a changed file is a new address.
const hashes = new Map();

function scriptOut(rel) {
  const text = readFileSync(join(src, rel), "utf8");
  return text.replace(/(from\s+")\.\/([\w-]+\.js)"/g, (_, from, name) => `${from}./${name}?v=${version(`js/${name}`)}"`);
}

function version(rel) {
  if (!hashes.has(rel)) {
    const body = rel.endsWith(".js") ? scriptOut(rel) : readFileSync(join(src, rel));
    hashes.set(rel, createHash("sha256").update(body).digest("hex").slice(0, 10));
  }
  return hashes.get(rel);
}

const versioned = (html) =>
  html.replace(/((?:href|src)=")\/((?:css|js)\/[\w-]+\.(?:css|js))"/g, (_, attr, rel) => `${attr}/${rel}?v=${version(rel)}"`);

const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function inline(s) {
  return escape(s)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
    .replace(/`([^`]+)`/g, "<code>$1</code>");
}

/** Just enough markdown for the legal pages: headings, lists, paragraphs. */
function markdown(md) {
  const out = [];
  let list = null;
  let para = [];
  const flush = () => {
    if (para.length) out.push(`<p>${inline(para.join(" "))}</p>`);
    para = [];
    if (list) out.push(`<ul>${list.map((li) => `<li>${inline(li)}</li>`).join("")}</ul>`);
    list = null;
  };
  for (const line of md.split("\n")) {
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    const item = line.match(/^[-*]\s+(.*)$/);
    if (heading) {
      flush();
      const level = heading[1].length;
      out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
    } else if (item) {
      if (para.length) flush();
      (list ??= []).push(item[1]);
    } else if (!line.trim()) {
      flush();
    } else if (list) {
      list[list.length - 1] += ` ${line.trim()}`;
    } else {
      para.push(line.trim());
    }
  }
  flush();
  return out.join("\n");
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

// Empty dist rather than delete it, so a local server running inside it survives a rebuild.
mkdirSync(dist, { recursive: true });
for (const name of readdirSync(dist)) rmSync(join(dist, name), { recursive: true, force: true });

for (const file of walk(src)) {
  const rel = relative(src, file);
  if (rel.startsWith("partials") || rel.endsWith(".md") || rel.endsWith(".DS_Store")) continue;
  const target = join(dist, rel);
  mkdirSync(dirname(target), { recursive: true });
  if (rel.endsWith(".html")) writeFileSync(target, versioned(render(readFileSync(file, "utf8"), {}, rel)));
  else if (rel.startsWith("js/")) writeFileSync(target, scriptOut(rel));
  else cpSync(file, target);
}

const pageTemplate = readFileSync(join(src, "partials/page.html"), "utf8");
for (const page of markdownPages) {
  if (!existsSync(page.file)) throw new Error(`missing ${page.file}`);
  // The markdown's own "# Title" is dropped: the template sets the heading.
  const body = readFileSync(page.file, "utf8").replace(/^---[\s\S]*?---\n/, "").replace(/^#\s+.*\n/, "");
  const content = render(markdown(body), {}, page.slug);
  const html = versioned(render(pageTemplate, { title: page.title, slug: page.slug, content }, page.slug));
  mkdirSync(join(dist, page.slug), { recursive: true });
  writeFileSync(join(dist, page.slug, "index.html"), html);
}

if (!storeUrl) console.warn("site: appStoreId is empty, so download buttons point at #download");
console.log(`site: built ${walk(dist).length} files into ${relative(root, dist)}`);
