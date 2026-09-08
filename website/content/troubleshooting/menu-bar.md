---
title: Menu bar and panel
description: Quota restrictions, icon-only layouts and display-position problems.
weight: 3
---

## Quota left despite a restriction

A session meter and a weekly meter describe different periods. Claude and Codex can block a session through an
account-wide or model-specific weekly limit. The status cells mark applicable restrictions even if you did not select
the blocking weekly row.

Open Usage to inspect the reported restriction and reset countdown. A day-only reset remains a date; **Reset due** means
the deadline passed but a new provider response has not confirmed the reset. It does not grant more quota.

## Icon-only or hidden menu bar item

Check model selection, **Hide 0%**, and **Fit to space** under Settings > Menu bar > Display options. No data, no
selected visible cells or an icon-only width fallback can leave only the app icon.

macOS can hide status items when there is insufficient room, including around the notch. Enable Detailed logging,
reproduce with the same frontmost app, and share the width-tier and button-frame entries. Include display arrangement
and scaling when reporting an arrow or panel-position problem.
