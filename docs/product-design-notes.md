# Proxy Workbench Product Design Notes

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
- Overview uses material panels, status pills, and compact stats to keep the app calm but polished.
- Proxy cards use an adaptive grid similar to professional Mac utilities: scannable names, endpoints, status, and direct actions.
- Global Proxy mode exposes `Use` directly on each proxy card; Rule-based mode hides that action to avoid confusion.
- The command palette uses a modal overlay instead of a separate navigation page, matching command-first Mac tools.

## Next Product Increments

- Add a menu bar extra for Start/Stop and current mode.
- Add first-run empty state when no profile has been imported.
- Add rule editor interactions: enable/disable rules, reorder, add simple domain rule.
- Add per-group selected proxy cards in Groups, so users do not need to read long policy strings.
- Add a packet/request inspector view focused on “what rule matched and why”.
