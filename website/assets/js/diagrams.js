// Mermaid takes its palette from the site tokens, so a diagram follows the light and dark themes.
(() => {
  // The theme classes live on <body>, so that is where the tokens resolve
  const token = (name, fallback) =>
    getComputedStyle(document.body).getPropertyValue(name).trim() || fallback;
  const blocks = [...document.querySelectorAll("pre.mermaid")];
  const sources = blocks.map((node) => node.textContent);

  const render = () => {
    if (!window.mermaid) return;
    const dark =
      document.body.classList.contains("theme-dark") ||
      (document.body.classList.contains("theme-auto") &&
        window.matchMedia("(prefers-color-scheme: dark)").matches);
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      // Draw at natural size and let CSS decide: shrinking a six-node flowchart to 390px leaves 4px labels,
      // so on a phone the stylesheet drops the cap and the block scrolls instead.
      flowchart: { useMaxWidth: false },
      sequence: { useMaxWidth: false },
      themeVariables: {
        background: token("--surface", "#ffffff"),
        primaryColor: dark ? "#272247" : "#efeafe",
        primaryBorderColor: token("--iris", "#5a46e8"),
        primaryTextColor: token("--ink", "#0f1117"),
        secondaryColor: dark ? "#1e3038" : "#e6f2f7",
        secondaryBorderColor: dark ? "#5087a0" : "#7fb3c6",
        tertiaryColor: dark ? "#2f2b1b" : "#faf3dc",
        tertiaryBorderColor: dark ? "#8c7c3f" : "#cbb46a",
        lineColor: token("--muted", "#667085"),
        textColor: token("--body", "#3c4250"),
        fontSize: "15px",
      },
    });
    blocks.forEach((node, index) => {
      node.removeAttribute("data-processed");
      node.textContent = sources[index];
    });
    window.mermaid.run({ querySelector: "pre.mermaid" });
  };

  const start = () =>
    window.mermaid ? render() : window.setTimeout(start, 50);
  start();
  document.addEventListener("themechange", render);
})();
