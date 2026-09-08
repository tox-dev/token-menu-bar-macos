---
title: Widgets
description: View selected quota models without additional provider requests.
weight: 7
---

Small, medium and large widgets read a shared snapshot of selected quota models. They do not fetch provider data. Signed
distribution builds include the extension; local ad-hoc bundles do not.

The app requests a widget reload after relevant changes, but macOS controls delivery and may delay it.
[Apple's widget refresh guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
describes that budget. A reload request does not guarantee that the widget matches the latest menu bar sample.
