---
title: Use quota in scripts
description: Read cached JSON for shell prompts or dashboards without another provider request.
weight: 8
---

Shell prompts and custom dashboards can read the app's last cached quota snapshot without another provider request:

```sh
"/Applications/Token Menu Bar.app/Contents/MacOS/TokenMenuBar" --usage-json
```

The command exits with JSON on stdout. Without a cache, it exits 1 with `usage export failed: no cached usage yet`; open
the app and allow a refresh to finish. It does not start the UI or fetch new data.

The JSON contains provider `id`, `plan`, `fetchedAt` and `windows`. Each window contains `id`, `label`, `usedPercent`
and an optional ISO-8601 `resetsAt`. It does not include credentials or email.

**Settings > Data > Collection and integrations > Write usage.json** writes that document to the support directory when
snapshots change. It is off by default. Leave it off unless an external script needs it; the app and widgets do not use
this file.

```sh
jq -r '.providers[] | .id as $provider | .windows[] | "\($provider) \(.label): \(.usedPercent)% used"' \
  "$HOME/Library/Application Support/Token Menu Bar/usage.json"
```

This path is for Direct and Homebrew builds. Use the sandbox support path for an App Store install. The file may be
stale if collection has stopped; inspect `fetchedAt`. Turning export off stops future writes, so do not treat an
existing file as evidence that export remains enabled.
