// Writes the logo in by hand, as the app does at launch
// (ios/CanWeGo/Views/CanWeGoLogoWriteOn.swift, `.launch` timing). Each
// letter's real outline shows only where a wide round pen has been; at rest
// the masks come off and it's the exact outline. Without this script, or
// with reduced motion, the finished logo simply shows.
(() => {
  const svg = document.querySelector(".logo");
  if (!svg || matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const PACE = 3200; // logo units per second
  const LIFT = 0.04; // between strokes of a letter
  const GAP = 0.04; // between letters
  const DOT = 0.26; // the question mark's dot, tapped in
  const DELAY = 0.15;

  const inks = [...svg.querySelectorAll(".lw-ink")];
  const items = [];
  let t = 0;
  for (const ink of inks) {
    const mask = svg.querySelector(ink.dataset.mask.slice(4, -1));
    const dot = mask.querySelector(".lw-dot");
    if (dot) {
      items.push({ el: dot, dot: true, r: +dot.dataset.r, start: t, duration: DOT });
      t += DOT;
    }
    const pens = [...mask.querySelectorAll(".lw-pen")];
    pens.forEach((pen, i) => {
      // Every segment is its own eased movement, so the pen slows into corners.
      const duration = Math.max(0.08, (+pen.dataset.len / PACE) * 1.12);
      pen.style.strokeDasharray = "1 1";
      pen.style.strokeDashoffset = "1";
      pen.style.visibility = "hidden";
      items.push({ el: pen, start: t, duration });
      t += duration;
      const next = pens[i + 1];
      if (!next) t += GAP;
      else if (next.dataset.stroke !== pen.dataset.stroke) t += LIFT;
    });
    ink.setAttribute("mask", ink.dataset.mask);
  }
  const total = Math.max(...items.map((it) => it.start + it.duration));

  let start;
  function frame(now) {
    start ??= now + DELAY * 1000;
    const time = (now - start) / 1000;
    for (const it of items) {
      const raw = Math.min(1, Math.max(0, (time - it.start) / it.duration));
      if (it.dot) {
        // A small overshoot before settling.
        const p = raw < 1 ? Math.max(0, 1 - (1 - raw) ** 2 * (1 - 2.2 * raw)) : 1;
        it.el.setAttribute("r", it.r * p);
      } else {
        // Minimum-jerk easing, like a reaching hand.
        const p = raw ** 3 * (10 - 15 * raw + 6 * raw * raw);
        it.el.style.visibility = p > 0 ? "visible" : "hidden";
        it.el.style.strokeDashoffset = String(1 - p);
      }
    }
    if (time < total) requestAnimationFrame(frame);
    else for (const ink of inks) ink.removeAttribute("mask");
  }

  // It sits below the phones, so it waits until it's on screen.
  new IntersectionObserver((entries, observer) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    observer.disconnect();
    requestAnimationFrame(frame);
  }, { threshold: 0.6 }).observe(svg);
})();
