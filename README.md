# FastTab

FastTab is a small macOS command bar for jumping between browser tabs, bookmarks, history, and Finder locations without stopping to hunt through windows.

This app is indie-made. The official build, updates, and license support are available at [fasttab.theindie.app](https://fasttab.theindie.app). If FastTab is useful to you, please buy it there.

## Honest Status

This repository is source-available, not an open source project in the usual maintenance-contract sense. I made the source available so curious users can inspect it, learn from it, build a local copy, or send focused fixes. I am not promising free support, a public roadmap, or ongoing maintenance work for every local build someone creates.

The version sold on the website is the supported product. It has the release packaging, update feed, signing/notarization, and production license configuration. A local build from this repository is best treated as a development build.

## What It Does

- Search open tabs, bookmarks, and browser history from supported browsers.
- Switch directly to a selected browser tab.
- Cycle recent tabs by pressing the FastTab shortcut repeatedly.
- Search Finder history and jump back to recent folders.
- Swipe or use row actions to close tabs, delete supported items, or copy links.
- Configure which supported apps are included.

Supported sources in the current codebase include Chrome-family browsers, Safari, Microsoft Edge, and Finder.

## Requirements

- macOS 14 or newer.
- Xcode with Swift 6 support.
- Accessibility permission for the global shortcut and window control.
- Automation permission for controlling supported browsers and Finder.
- Full Disk Access may be needed if browser history or bookmarks do not appear.

## Get It Running Locally

Clone the repo and enter it:

```sh
git clone <repo-url>
cd command-bar-macos
```

Resolve dependencies:

```sh
swift package resolve
```

Run the test suite:

```sh
swift test
```

Run a local development build:

```sh
swift run FastTab
```

On first launch, macOS may ask for permissions. If results are empty or actions fail, open System Settings and check:

- Privacy & Security -> Accessibility: allow FastTab or the terminal/Xcode process running it.
- Privacy & Security -> Automation: allow FastTab to control the browsers/Finder you want to use.
- Privacy & Security -> Full Disk Access: allow the running app or development tool if browser history/bookmark databases are blocked.

## Local Build Caveats

The local SwiftPM build is useful for development and inspection, but it is not the same as the signed release build.

- Production checkout, license activation, and app updates are configured for the official distributed app.
- The repo does not include private signing keys, notarization credentials, or release automation secrets.
- Official license keys are meant for the official build from [fasttab.theindie.app](https://fasttab.theindie.app), not arbitrary local development bundles.
- Sparkle update metadata exists in the product, but local builds should not be expected to update like the official app.

## Building Your Own App Bundle

For personal development, `swift run FastTab` is the simplest path. If you want a standalone `.app`, you will need to provide your own bundle identifier, signing setup, Info.plist values, and packaging flow.

The release app uses configuration keys for things like checkout URLs, license validation, support links, and Sparkle updates. Those production values are intentionally part of the official distribution path, not a promise that every source checkout is a supported release build.

## Contributing

Small, practical fixes are welcome. The most useful contributions are reproducible bug reports, focused patches, and tests around behavior that changed. Large feature requests or support expectations are better directed through the official product channel after purchasing the app.

## License

Copyright is retained by the app author. Unless a separate written license says otherwise, this repository does not grant an open source license to copy, redistribute, resell, repackage, or publish modified versions of FastTab.

You may read the source, build it locally for personal evaluation, and submit focused fixes. If you want to use FastTab as a product, please use the official build from [fasttab.theindie.app](https://fasttab.theindie.app).

## Support

If you are using the official app, use the support path linked from [fasttab.theindie.app](https://fasttab.theindie.app). If you are running a local build, please assume you own the local build environment and any changes you make to it.
