---
title: Token Menu Bar
---

## Made to stay out of the way

- Polls Claude every 5 minutes and Codex every 2 (faster while the popover is open), with backoff when a vendor asks to
  slow down, because Anthropic's usage endpoint rate-limits after a handful of calls.
- Falls back to the Codex CLI's own session logs when you are offline or signed out, so the numbers never vanish.
- Pauses while the Mac sleeps and refreshes on wake.
