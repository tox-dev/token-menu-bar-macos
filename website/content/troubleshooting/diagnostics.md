---
title: Collect diagnostics
description: Reproduce a fault, filter logs and prepare a report without exposing secrets.
weight: 1
---

1. Enable **Detailed logging** under Settings > Log before reproducing a UI or refresh problem.
2. Reproduce it, then open **View log**. Filter by level or text, or choose **Show Full Log**.
3. Use **Copy Diagnostics** in the Settings footer, or **Report Issue** in the shared footer. Review the text before
   sharing it.
4. Turn Detailed logging off when finished.

The inline viewer shows up to 200 recent lines. The memory buffer holds 500; disk logging rotates three files of up to 1
MiB each and prunes entries older than seven days. File writes can lag the memory view by five seconds. Log timestamps
use UTC to correlate events across machines.

Detailed events include provider outcome and duration, analytics inclusion, panel anchor and screen geometry, tab
measurement ownership, status-item width tiers and their triggers. Ordinary missing-provider discovery is debug
information, not a reason to fill the default log with errors.

Network logs omit request headers and response bodies. URLs lose query strings and mask UUIDs. Diagnostics still include
provider state, plans, usage and safe local paths, so check for identifying information before posting.

**Report Issue** fits whole lines into an 8,000-character URL; the log tail may not fit. **Copy Diagnostics** includes
the report for manual pasting and up to 80 recent log lines.

The History row in Settings > Data shows the support location. Direct and Homebrew log files are next to the database
under `~/Library/Application Support/Token Menu Bar/`; the App Store uses its sandbox container.
