export type NavItem = {
  name: string;
  href: string;
};

export type NavSection = {
  title: string;
  items: NavItem[];
};

export const navSections: NavSection[] = [
  {
    title: "Getting Started",
    items: [
      { name: "Introduction", href: "/" },
      { name: "Quick Start", href: "/quick-start" },
      { name: "Examples", href: "/examples" },
      { name: "App Model", href: "/app-model" },
      { name: "Frontend Projects", href: "/frontend" },
      { name: "Migration Guide", href: "/migrating" },
    ],
  },
  {
    title: "Core Concepts",
    items: [
      { name: "Web Engines", href: "/web-engines" },
      { name: "Windows", href: "/windows" },
      { name: "Multiple WebViews", href: "/webviews" },
      { name: "Bridge", href: "/bridge" },
      { name: "Builtin Commands", href: "/bridge/builtin-commands" },
      { name: "Type-Safe IPC", href: "/bridge/codegen" },
      { name: "Dialogs", href: "/dialogs" },
      { name: "System Tray", href: "/tray" },
      { name: "Security", href: "/security" },
    ],
  },
  {
    title: "Tooling",
    items: [
      { name: "CLI Reference", href: "/cli" },
      { name: "Dev Server", href: "/cli/dev" },
      { name: "Packaging", href: "/packaging" },
      { name: "Code Signing", href: "/packaging/signing" },
      { name: "CI/CD", href: "/packaging/ci" },
      { name: "Updates", href: "/updates" },
      { name: "app.zon Reference", href: "/app-zon" },
      { name: "Manifest Reference", href: "/manifest" },
      { name: "Capabilities", href: "/capabilities" },
      { name: "App Sandbox", href: "/sandbox" },
    ],
  },
  {
    title: "Operations",
    items: [
      { name: "Debugging", href: "/debugging" },
      { name: "zero-native doctor", href: "/debugging/doctor" },
      { name: "Automation", href: "/automation" },
      { name: "Testing", href: "/testing" },
    ],
  },
  {
    title: "Advanced",
    items: [
      { name: "Extensions", href: "/extensions" },
      { name: "Bundled Plugins", href: "/extensions/plugins" },
      { name: "Embedded App", href: "/embed" },
      { name: "Package Distribution", href: "/packages" },
    ],
  },
  {
    title: "API Reference",
    items: [
      { name: "Runtime", href: "/api/runtime" },
      { name: "Dispatcher", href: "/api/dispatcher" },
      { name: "Channel", href: "/api/channel" },
      { name: "Metadata", href: "/api/metadata" },
      { name: "Capability", href: "/api/capability" },
      { name: "ModuleRegistry", href: "/api/module-registry" },
      { name: "Sandbox", href: "/api/sandbox" },
    ],
  },
];

export const allDocsPages: NavItem[] = navSections.flatMap((s) => s.items);
