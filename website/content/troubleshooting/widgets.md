---
title: Stale widgets
description: Check the build channel, snapshot and macOS refresh budget.
weight: 5
---

Check that the distribution build and its widget use the same app group, and that the app has fetched new data. Local
development bundles do not include the widget extension; demo verification does not update the real widget.

The app requests reloads after relevant snapshot changes. WidgetKit controls when those requests take effect, so widgets
can lag behind the menu bar even while the app is running. See
[Apple's refresh budget](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).
