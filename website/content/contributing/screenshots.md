---
title: Documentation images
description: Capture the current UI with sample data and review the output.
weight: 5
---

```sh
just shots
```

The script rebuilds the app, then runs `--export-menubar` and `--export-popover` with isolated demo state, disabled
network transport and mock credentials. It waits for History data before drawing. The eight WebP assets cover the menu
bar and three tabs in both appearances, bounded to a laptop-sized viewport. Commit them with UI changes that affect the
documented screens; website CI builds those assets but does not regenerate them.

Use `APP_BINARY=/absolute/path/to/TokenMenuBar just shots` only to capture a binary you have verified matches the
source. Compare Settings > About's source version with the binary you intend to document. Inspect the full images for
loading states, clipped text and missing sections before publishing. The site build rejects missing shortcode images and
unresolved internal page links.

These exports do not create an `NSPopover` or a window-server surface. They cannot verify the arrow, control bezels,
focus rings, screen selection, or top-edge anchoring.

The social-preview image has a separate SVG source beside the rendered PNG. After editing it, install `librsvg` and run:

```sh
rsvg-convert website/static/brand/og.svg --output website/static/brand/og.png
rsvg-convert website/static/brand/icon.svg --width 32 --height 32 --output website/static/brand/icon-32.png
rsvg-convert website/static/brand/icon.svg --width 180 --height 180 --output website/static/brand/icon-180.png
```

Inspect the 1200 × 630 PNG before committing both files; social previews use the PNG.
