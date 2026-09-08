---
title: Website
description: Preview the Hugo site and maintain links, diagrams and brand assets.
weight: 6
---

`website/` is a self-contained [Hugo](https://gohugo.io) site built from plain CSS and templates, with no theme module,
Node or Sass. Task pages cover installation, provider setup, reference material and development.

```sh
just site-serve
```

The brand lives in two places that have to stay in step: `Sources/TokenMenuBarCore/Brand.swift` for the app, and the
custom properties at the top of `website/assets/css/site.css` for the site. `website/static/brand/` holds the logo files
(`mark`, `mark-mono`, `lockup`, `lockup-stacked`, `icon`, `seal`). Each page also ships as raw markdown next to itself,
and `/llms.txt` indexes them for crawlers in the [llms.txt](https://llmstxt.org) format.

Diagrams are [Mermaid](https://mermaid.js.org) fenced blocks. The renderer loads only on pages that hold one, and takes
its palette from the site tokens, so a diagram follows the light and dark themes.
