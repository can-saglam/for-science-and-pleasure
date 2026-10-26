// Can We Go? — the invite page. Reads the code from /join/KV7P2M (or
// ?code=KV7P2M when testing locally), shows it with a copy button, and
// points "Open the invite" at the app. Codes are six letters or digits,
// as the app expects (DigestGate.swift).

const fromPath = location.pathname.split("/").filter(Boolean)[1] ?? "";
const raw = new URLSearchParams(location.search).get("code") ?? fromPath;
const code = decodeURIComponent(raw).toUpperCase().replace(/[^A-Z0-9]/g, "");

if (code.length === 6) {
  const panel = document.querySelector("[data-join]");
  panel.querySelector("[data-code]").textContent = code;
  panel.querySelector("[data-open]").href = `canwego://join/${code}`;

  const copy = panel.querySelector("[data-copy]");
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code);
      copy.textContent = "Copied";
    } catch {
      copy.textContent = "Select and copy";
    }
    setTimeout(() => (copy.textContent = "Copy"), 2000);
  });

  panel.hidden = false;
} else {
  document.querySelector("[data-join-missing]").hidden = false;
}
