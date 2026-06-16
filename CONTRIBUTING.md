# Contributing

Thanks for helping improve zero-native. This guide is for maintainers and contributors working on the framework repository itself.

For app author documentation, start at [zero-native.dev](https://zero-native.dev).

## Prerequisites

- [Zig 0.17.0+](https://ziglang.org/download/)
- Node.js with npm for the CLI package and generated frontend projects
- pnpm for the documentation site
- macOS for WKWebView and Chromium/CEF development
- Linux with GTK4 and WebKitGTK 6 for Linux system WebView development

## Local Checks

Run the framework tests:

```bash
zig build test
```

Validate the sample app manifest:

```bash
zig build validate
```

Build the WebView example against the system engine:

```bash
zig build test-webview-system-link
```

Run the WebView example:

```bash
zig build run-webview
```

Check the npm CLI package:

```bash
npm --prefix packages/zero-native run version:check
npm --prefix packages/zero-native run scripts:check
```

Check the documentation site:

```bash
pnpm --dir docs install --frozen-lockfile
pnpm --dir docs check
```

## Web Engine Development

The system WebView path is the default development loop:

```bash
zig build run-webview -Dweb-engine=system
```

For Chromium on macOS, install CEF and run with the Chromium engine:

```bash
zero-native cef install
zig build run-webview -Dweb-engine=chromium
```

Useful Chromium smoke checks:

```bash
zig build test-webview-cef-smoke -Dplatform=macos -Dweb-engine=chromium
zig build test-package-cef-layout -Dplatform=macos
```

## Packaging Development

Create a local package artifact:

```bash
zig build package
```

Package explicitly through the CLI:

```bash
zero-native package --target macos --manifest app.zon --assets assets --binary zig-out/lib/libzero-native.a
```

For Chromium packages, configure `.web_engine = "chromium"` and `.cef` in `app.zon`, or use temporary `--web-engine` and `--cef-dir` overrides while testing.

## Automation Development

Enable automation in a build:

```bash
zig build run-webview -Dautomation=true
```

Interact with the running app:

```bash
zero-native automate wait
zero-native automate list
zero-native automate bridge '{"id":"ping","command":"native.ping","payload":null}'
```

Automation writes artifacts under `.zig-cache/zero-native-automation`.


## Making a Pull Request
Thank you for your contribution! Please follow these steps to ensure a smooth review process:
1. Fork the repository and create a new branch for your feature or bug fix.
2. Make your changes and commit them with clear, descriptive messages.
3. Push your branch to your forked repository.
4. Open a pull request against the main repository's `main` branch.

Please cryptographically sign your commits so they show as **Verified** on GitHub. This requires a GPG or SSH signing key added to your GitHub account — see [GitHub's guide](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification). Note: the `Signed-off-by` trailer (`git commit -s`) is a DCO attestation and does **not** produce the Verified badge; you need `git commit -S` (uppercase) or `commit.gpgsign = true` in your git config.