# With Plugins Example

A zero-native app that loads three bundled plugins from `app.zon` and exposes
them to a webview. The `index.html` page has three buttons that invoke
`clipboard.write_text`, `notification.notify`, and `store.set` through the
`window.zero.invoke` bridge.

## What's in `app.zon`

```zon
.plugins = .{ "clipboard", "notification", "store" }
```

The plugin names are also declared in `src/main.zig` and forwarded to
`Runtime.loadPlugins` via `RunOptions.plugin_names`. `loadPlugins`
instantiates the corresponding `extensions.Module` values and wires
them into the runtime registry; `Runtime.deinit` releases them on
shutdown. The `app.zon` is the user-facing source of truth — keep the
two lists in sync when adding or removing plugins.

## Run

```bash
zig build run
```

## Tests

```bash
zig build test
```

## Using outside the repo

This example references zero-native via relative path (`../../`). To use it
standalone, override the path:

```bash
zig build run -Dzero-native-path=/path/to/zero-native
```

Or, when a published Zig package is available, replace
`default_zero_native_path` in `build.zig` with the package URL and add it to
`build.zig.zon` dependencies.
