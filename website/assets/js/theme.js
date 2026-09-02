// The stored choice is applied by an inline script in <body> before paint, so this file only wires the toggle.
(() => {
  const body = document.body;
  const toggle = document.getElementById("theme-toggle");
  const icon = document.getElementById("theme-icon");
  const moon = "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z";
  const sun =
    "M12 4v1m0 14v1m8-8h-1M5 12H4m13.7-5.7-.7.7M7 17l-.7.7m11.4 0-.7-.7M7 7l-.7-.7" +
    "M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z";

  const isDark = () =>
    body.classList.contains("theme-dark") ||
    (body.classList.contains("theme-auto") &&
      window.matchMedia("(prefers-color-scheme: dark)").matches);

  const paintIcon = () => {
    const dark = isDark();
    if (icon) icon.setAttribute("d", dark ? sun : moon);
    if (toggle) toggle.setAttribute("aria-pressed", String(dark));
    // Diagrams pick their palette at render time, so they need to hear about the switch
    document.dispatchEvent(new CustomEvent("themechange"));
  };

  if (toggle) {
    toggle.addEventListener("click", () => {
      const next = isDark() ? "light" : "dark";
      body.classList.remove("theme-auto", "theme-light", "theme-dark");
      body.classList.add("theme-" + next);
      localStorage.setItem("tmb-theme", next);
      paintIcon();
    });
  }

  window
    .matchMedia("(prefers-color-scheme: dark)")
    .addEventListener("change", paintIcon);
  paintIcon();
  requestAnimationFrame(() => body.classList.remove("preload"));
})();
