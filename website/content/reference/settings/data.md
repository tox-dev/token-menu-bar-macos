---
title: Data settings
description: Retention, history export and collection options.
weight: 4
---

- **Retention** defaults to 60 days; choose 7–365. Reducing it prunes older history.
- **History** shows the full database path with **Open** and **Clear…**. Long paths scroll rather than truncate. Clear
  requires confirmation.
- **Export History…** exports stored history. History's **Export CSV** exports its selected metric and period instead.

**Collection and integrations** holds the less frequent options:

| Control                       | Default and effect                                                                                                                           |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Analytics                     | 15 minutes; choose 5–120 in steps of five. This clock is separate from provider quota polling and appears when applicable.                   |
| Expect usage on N days a week | 7; choose 4–7 for pacing of periods longer than a day. Fewer days distribute expected use over Monday through the chosen weekday.            |
| Write usage.json              | Off. Writes quota snapshots for shell prompts or local dashboards without extra provider requests. The app and widgets do not use this file. |

[Script examples](/reference/scripting/) describe the JSON fields and command-line alternative.
