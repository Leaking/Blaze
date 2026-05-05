# blaze Product Design Notes

## Product Scope

The product should feel like a practical Mac network utility, not a developer-only config editor. The first-run path is:

1. Paste or import a profile.
2. Validate the profile and rule sets.
3. Choose Direct, Global Proxy, or Rule-based Proxy.
4. Start local proxy takeover.

Proxy, Group, and Rule remain the core management surfaces. Advanced debugging, export, and source editing stay secondary.

## Reducing The Usage Threshold

- Make the Overview page a control center, not a settings list.
- Keep one primary action visible: Start.
- Make profile import persistent and explicit: imported profiles are saved locally and restored on launch.
- Show a four-step setup strip so users know whether Import, Rules, Policy, and Takeover are ready.
- Add a command palette for power users: Start, Stop, Import, Test All, and page navigation.
- Keep warnings visible but non-blocking. For example, unsupported `GEOIP` is shown as a compatibility warning rather than hidden.

## Visual Direction

Research notes:

- Apple HIG sidebars: sidebars are appropriate for broad app sections and should expose peer areas of the app clearly.
  Source: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Raycast: a searchable command entry lowers the cost of discovering actions.
  Source: https://manual.raycast.com/search-bar
- Raycast system commands: commands make system-level actions reachable without digging through menus.
  Source: https://manual.raycast.com/system-commands
- Linear: command-menu and keyboard-driven workflows are treated as primary navigation.
  Source: https://linear.app/docs/peek
- CleanShot X: workflow tools benefit from quick access, focused overlays, and immediate post-action options.
  Source: https://cleanshot.com/

Applied decisions:

- Native macOS sidebar and toolbar remain the shell.
- The sidebar now follows the reference product structure: Overview, Proxies, Rules, Rule Sets, Profiles, Traffic, DNS, Logs, and Settings.
- Overview uses material panels, status pills, and compact stats to keep the app calm but polished.
- Overview is a control center with connection, system proxy, local takeover, active profile, latency, diagnostics, traffic, and activity panels.
- Proxy cards use an adaptive grid similar to professional Mac utilities: scannable names, endpoints, status, and direct actions.
- Proxies now use a dense table plus an inspector, matching the reference image's management workflow and making latency, health, favorites, and global selection visible at once.
- Rules now combine category navigation, a rule list, and a focused inspector/editor panel so simple rule edits do not require opening raw source text.
- Rule Sets, Traffic, DNS, Logs, and Settings are first-class pages instead of being hidden under generic advanced areas.
- Global Proxy mode exposes `Use Globally` directly in the proxy inspector; rule-based mode remains the default routing workflow.
- The command palette uses a modal overlay instead of a separate navigation page, matching command-first Mac tools.
- The menu bar extra now mirrors the reference quick switch: connection state, active routing, connect/disconnect, auto-select, global policy switching, import, and latency test.

## Next Product Increments

- Add first-run empty state when no profile has been imported.
- Add rule editor interactions: enable/disable rules and reorder.
- Add per-group selected proxy cards in Proxies or Profiles, so users do not need to read long policy strings.
- Add a packet/request inspector view focused on “what rule matched and why”.
