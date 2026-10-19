# CLAUDE.md — devmachine-app

Native macOS app (Swift 6 / SwiftUI / AppKit, SwiftPM) that operates the
`devmachine` VPS: tmux sessions per context-user, PRs, files, Caddy subdomains,
VPS stats, and coding-harness usage. It reads the devmachine CLI's configuration
folder (`~/.config/devmachine`) and publishes through the CLI.

## Language — ABSOLUTE, overrides everything
**All code, identifiers, comments, and git commit messages are ENGLISH.** No
Portuguese anywhere in this repo. (Chat with the owner stays Portuguese; that
never leaks into the code or commits.) This rule wins over any base preference.

## No real data — absolute, overrides everything
**This repo never holds real infrastructure or personal data**: real
workspace/context user names, client or product names, hostnames, public or
tailnet IPs, domains, emails, tokens. Not in code, tests, fixtures, docs,
comments, commit messages, screenshots or assets.

- Fixtures use invented names: workspaces `acme`, `beta`, `gamma`; people
  `alice`, `bob`; repos `acme/dash`; domains `example.com` / `example.net`; Mac
  paths under `/Users/alice`; IPs from the documentation ranges `203.0.113.x`
  (public) and `100.64.0.x` (tailnet); PR numbers arbitrary.
- Real values enter only two ways: the app's Setup/Settings page (`AppSettings`,
  persisted in `UserDefaults`) and the CLI's configuration folder on disk. A feature that needs an
  infra value reads `AppSettings`; it never carries a literal.
- Before any push run `scripts/check-real-data.sh`. It greps the tree with the
  owner's private pattern list (`~/.config/devmachine-app/private-patterns`,
  outside the repo on purpose — the list itself is real data) and must print
  nothing. The one allowed hit is `2BUA8C4S2C.com.1password` (the 1Password
  agent socket path in `RemoteCommands.swift`) — a product default.

## "Page" = a central panel, NEVER a new window
When the owner asks for a feature or "a page", he wants something that loads
**in the middle of the app** (the central content area), like a new home screen —
**not** a new macOS window. Default to a central page.

- The center is polymorphic, driven by `AppModel.activePage: AppPage?`. `nil` =
  normal behavior (the selected session's terminal, or Home when nothing is
  selected). A non-nil `activePage` renders that page full-size in the center,
  over the (still-mounted, hidden) terminals — so switching to a page never tears
  down a live ssh/tmux terminal.
- Selecting a session or the ops shell clears `activePage` (back to the terminal).
- Sidebar / menu bar entries for pages (Stats, Published apps, …) SET `activePage`;
  they do NOT `openWindow`.
- **Settings is a page too** (`AppPage.setup`, `SetupPage` in `PageHost`), with
  the sidebar beside it, never a window or a full-window card: ⌘,, the
  sidebar's gear, the palette, menus and every remedy button set it. The Add
  machine wizard opened from Settings → Machines closes back there
  (`AppModel.closeAddMachine`); opened from anywhere else it just closes.
- Create a new `Window` ONLY when the owner explicitly asks for a separate window.
  Existing exception: the **Files** window is contextual per-workspace (opened
  from the sidebar folder button) and stays a window for now.

## Command palette (⌘K)
- `CommandRegistry` builds every command from a `PaletteContext` (plain values:
  workspaces, sessions, machines, the current terminal). A fixed command carries
  an `isAvailable` check; per-workspace, per-machine and per-session commands
  are generated from state. A new screen or sheet gets a command there.
- A command is data (`PaletteAction`); `PaletteDispatcher` is the one place that
  runs it, through the same `AppModel` calls the sidebar and menus use. A sheet
  that lives in a view opens through a model request (`pendingAddSubdomain`,
  `pendingPublishWorkspace`, `requestedSettingsSection`), never a second copy.
- Ranking is `FuzzyMatch` (Core) plus the recent-use bonus from `CommandMRU`,
  persisted by `PaletteRecentsStore`.

## Menubar
`MenuBarExtra` uses `.menuBarExtraStyle(.window)`: an interactive popover. The
title and the popover are widget boards (engine 1.4), owned by one
app-scoped `MenubarController.shared`:

- **Two files.** `<config>/boards/menubar.yml` (surface `menubar`, layout
  `slot`) and `<config>/boards/menubar-panel.yml` (surface `menubar-panel`,
  layout `tabs`). Same envelope and store rules as the sidebars
  (`StackBoardStore`, `StackBoardController`): disk wins, 300 ms write, an
  invalid file is never written over (the popover shows the banner), reset
  keeps `.bak`. A slot entry has no `frame`, `size`, `collapsed`, `z` or
  `minimized`; at most 3, left to right. A tab has no `frame`, `z`,
  `minimized` or `collapsed`; its `size` is kept on write and ignored.
- **Defaults are today** (`DefaultStackBoard`): `[brand, open-pull-requests]`
  and `[pull-requests-panel, usage-panel]`, no `size`. They resolve built in
  (`AppMenubarWidgets`), so a missing CLI or packages release never changes
  the title or the tabs. `MenuBarLabelTests` pins today's label pixels; keep
  it green.
- **The title is text plus one SF Symbol per slot** (`MenubarLabelModel`),
  so macOS can template it. A slot draws `text` (first non-empty line, cut
  at 24 characters counting the "…"), `number`, `status` (a symbol per
  level: colour is lost in the menu bar) or `app.brand` ("❯_"). Any other
  view is refused. A `number` view with `hide_zero: true` draws nothing at 0
  (the built-in open pull request count sets it); without it, 0 shows. With
  nothing to draw, the title shows "❯_", so the item never vanishes.
- **Who runs when.** The title's widgets run from launch, window or not
  (`DevmachineApp.init` starts the controller; never a view, never a test).
  A slot source's `every` is raised to 30 s, and a stream is refused. The
  popover's widgets run only while it is open, and only the selected tab
  (`StackBoardController.setVisibleEntries`); Edit mode shows no tab, so
  none runs. Open and close come from `onAppear`/`onDisappear` and also
  from the menu bar window's `didBecomeKey`/`didResignKey`
  (`MenubarPanelWindowWatch`), because a `MenuBarExtra` window kept alive
  between opens may skip them. `MenubarPanelPresence` lets only the first
  signal of an open or a close act; a window that gives up key but stays
  on screen stays open. The title's ticks never redraw the popover: the
  controller publishes only what the popover reads (`approvals`).
  `PRStore` and `HarnessUsageStore` keep their own schedules; the providers
  `app/open-pull-requests`, `app/pull-requests-panel` and `app/usage-panel`
  only read them. The 30 s floor and the 24-character cut are the app's;
  the CLI only carries the numbers in the contract.
- **Wrap, never rewrite.** The Pull Requests tab is `PRsView` as it is; the
  Usage tab is `MenuBarUsageColumns`, the old block moved as it was. Width
  776 and height 640 for every tab (`MenuBarSizing`, `UsageLayoutTests`).
- **Approval.** A title widget waiting for approval draws "!" in its slot;
  a denied one draws nothing. Both are listed, as their `SourceWidgetCard`,
  in an "Approvals" tab that comes first and is selected when the popover
  opens. An answer given in any area (Home, the sidebar, the Context tab, the popover)
  reaches the title at once: see "A widget written in the board runs only
  after Allow" for how every area shares the approvals file.
- **Edit mode** (pencil in the footer) lists both boards with up, down and
  remove, and "Add widget" opens `WidgetGalleryView` in place, filtered to
  that surface. A full menu bar disables "Add widget" and says why ("The
  menu bar holds 3 widgets", `StackGallery.fullReason`), and a placed
  widget never makes a fourth slot.
- **Settings → Appearance** resets the menu bar and the menu bar popover
  ("Reset menu bar", "Reset menu bar popover") under their own "Menu bar"
  heading, after "Sidebar and Context tab"
  (`StackBoardController.reset()`, `.bak` kept).
- Test hook: `DEVMACHINE_WIDGETS_E2E=<binary>` runs `MenubarBoardLiveTests`
  against a temp config: the CLI validates the app's default boards,
  refuses a fourth slot and a slot `size`, and moves a tab keeping an
  inline entry byte for byte. No test reads `MenubarController.shared`.

The footer's eyedropper and ⌘K's "Pick a color from the screen" share
`ScreenColorPicker` (the system `NSColorSampler`); the clipboard text is
`ScreenColor.hex` (Core), converted to sRGB first so the hex matches what a
web page or design tool means by it.

## Reusable structure
- `DevmachineCore` (library): pure logic, parsers, command builders — unit-tested,
  no UI, no AppKit where avoidable.
- `HarnessUsageKit` is the reusable multi-provider usage data layer and views.
  It depends only on Foundation/SwiftUI/Charts, never on the app target.
- `DevmachineApp` (executable): the app shell + SwiftUI views.
- `HarnessRegistry` owns provider adapters. SwiftUI consumes descriptors and
  facades; executable names, process matching, colors, launch commands, and
  provider policies stay behind adapters.
- `DevmachineServices` is the boundary for workspace, session, and context data.
  Its current sources preserve the existing SSH and `devmachine-infer` behavior;
  a future `devmachine-cli` source can replace them without changing views.
- Shared UI lives in `Sources/DevmachineApp/Components/` + `Theme.swift`
  (`Color.dm*`). See "Component library" below.

## Component library — use what exists, never reinvent
`Sources/DevmachineApp/Components/` is the app's own component library. Before
writing any UI, look there first. The order is fixed:

1. **A `DM*` component or style already does it** → use it. Add a parameter if
   it is close but not quite right; do not copy it.
2. **Nothing in `Components/` fits** → use the native SwiftUI/AppKit control
   (`Toggle`, `Picker`, `Menu`, `.bordered`, `.borderedProminent`, `.link`,
   `.roundedBorder` in a native sheet).
3. **Neither fits and the thing appears twice** → add a new `DM*` component to
   `Components/`, then use it in both places. One-off layout stays in its view.

What is there:
- Tokens (`DMTokens.swift`): `DMRadius.*` for every corner radius, `DMHitSize.*`
  for icon click areas, `DMSpace`, `DMControlHeight`, `DMIconSize`, `DMRowInset`,
  `DMSectionInset`, `DMCardWidth`, `DMPaneWidth`, all in points at 100%;
  `Color.dm*` (incl. `dmSelection`, `dmStroke`, `dmActive`). No number literals
  for radii in views.
- Metrics (`DMMetrics.swift`): the app's `rem`. One rem is the 13-point body
  size times Settings → Appearance → text size (`uiFontScale`), and every token
  comes back scaled from `@Environment(\.dmMetrics) private var m`:
  `m.space.md`, `m.control.small`, `m.radius.row`, `m.card.banner`,
  `m.pt(7)` for a one-off point value, `m.rem(1.5)`. At 100% each token is
  exactly the old point value, so the default look never moves.
- Buttons (`DMButton.swift`): `DMButton` / `.buttonStyle(.dm(_:size:))` for every
  labelled button. Variants: `.primary` (the one action of a sheet or page),
  `.outline` (the action beside it, Cancel), `.danger` / `.dangerOutline` (ends or
  removes something), `.ghost` (toolbars, quiet inline actions), `.ghostDanger`
  (a quiet remove in a row, red only on hover), `.link` (reads as text). Sizes `.small`, `.regular`, `.large`; `isLoading:` shows a spinner and
  disables it. An icon-only button is `DMButton(icon:label:)`: the label is
  required and is what VoiceOver reads. Native buttons stay only in menus,
  context menus and `.confirmationDialog`.
- `DMButtons.swift`: `DMIconButton` / `DMIconButtonStyle` for a bare SF Symbol in
  dense chrome (sidebar, table rows, panel headers); `.dmChip` for suggestion and
  shortcut chips.
- Error state (`DMErrorState.swift`): `DMErrorStateView` for a failed read: a
  title, one plain likely cause (`FailureCause` in Core, `HarnessUsageErrorKind`
  for usage), Try again, and a collapsed "Show details" with the exact error to
  select and copy. `DMStatusView(.failed)` draws it, so a page gets it for free.
  Never dump an error string straight into a card. Usage cards get it through
  `.harnessUsageErrorView { … }`, since `HarnessUsageKit` cannot import it.
  A cause only a newer CLI fixes (`FailureCause.needsCLIUpdate`: ssh's
  `unix_listener: … too long for Unix domain socket`, an older CLI's
  connection socket under a long home folder) adds "Update the CLI", which
  opens Settings → About through `\.dmOpenCLIUpdate` (set at the root);
  Stats' banner offers it too.
- Jobs and age (`DMJobCard.swift`, `DMAgeLabel.swift`): `DMJobCard` for a job
  that runs in named steps and ends in a result to act on (same surface as
  `DMToastCard`, `.dmToastChrome()`); `DMAgeLabel` says how old cached data
  is, only once it is old enough to matter.
- Commands (`DMCommandBlock.swift`): `DMCommandBlock` for shell commands to
  select or copy (one or more lines, one Copy button); `DMCopyButton` alone.
- Logs (`DMLogView.swift`): `DMLogView` for a program's output as it comes
  (monospaced, colour codes out via `LogText`, follows the last line,
  Expand, Copy log; `fills` on a run screen). Every streamed output uses it.
- `DMReportBugButton`: opens a prefilled, redacted GitHub issue (`BugReport`)
  in the browser; every failure panel carries one.
- `DMChoiceCard(locked:)`: checked and never toggled (essentials).
- Fields (`DMFields.swift`): `DMSearchField` (magnifier + borderless field +
  trailing slot, optional focus binding); `.dmField()` for a text input on a
  dark surface.
- Surfaces (`DMSurfaces.swift`): `.dmGlass(radius:)` / `.dmGlass(in:)` for frosted
  cards, palettes, toasts; `.dmSurface(_:radius:)` for any filled shape with a
  hairline edge; `DMKeyCap`; `DMChip`.
- Rows and sections (`DMComponents.swift`): `DMRow`, `DMRowBackground`
  (radius and selected colour are parameters), `DMSection`, `DMSectionLabel`,
  `DMSectionValue`, `DMTableRow` (striped, hover-lit table row), `DMHairline`,
  `DMPill` (a status), `DMKindLabel` (a kind: one calm style, no colour per kind),
  `DMPRStateIcon` (a PR's open/draft/merged/closed glyph), `DMProgressBar`,
  `DMStatBubble`, `DMToastCard`; `DMTabStrip` (`grouped: true` for a segmented
  second level), `FlowLayout`.

Rules:
- **No fixed points in components; use tokens.** A padding, frame, stack
  spacing, radius or width in `Components/` comes from `DMMetrics`, so a bigger
  text size grows the box with the text instead of spilling out of it.
  `DMFixedPointsGuardTests` fails on a new literal (0 and 1-point hairlines
  are allowed). A component parameter is in points at 100%, like a `.dm(_:)`
  font size, and the component scales it: never pass it `m.…`. Screens use
  `m.…` too; a `static` helper with no environment reads `DMMetrics.current`.
  `DMComponentsFitTests` draws each component at 80/100/130/160% and fails when
  it spills out of its frame or stops growing with the text: add a new
  component there.
- Never hand-roll `.buttonStyle(.plain)` + `Image` + `.foregroundStyle` +
  `.frame` + `.contentShape` for an icon button: that is `DMIconButton`.
  `.buttonStyle(.plain)` stays only for a button whose label is a whole row or
  panel.
- Never write `.background(.ultraThinMaterial, in:)` + a stroke overlay: that is
  `.dmGlass`.
- `DMComponentsRenderTests` renders a gallery of every component; add a new
  component to it. `DEVMACHINE_RENDER=1 swift test --filter DMComponentsRenderTests`
  writes `/tmp/devmachine-components.png` to look at.
- `HarnessUsageKit` never imports app components (it depends only on
  Foundation/SwiftUI/Charts); it keeps its own small styles.
- No third-party UI kit (e.g. shadcn ports): they bring a web look, blur-heavy
  overlays and their own window/hosting code, which clash with the hard UI rules
  below.

## Hard UI rules
- **Few lines.** The owner reads a screen full of dividers as noise. Areas
  are separated by spacing first, then by a faint tint (`Color.dmBand`,
  `Color.dmHover`); tables have no outer border and no line between rows
  (`DMTableRow`); tab rows are pills, never underlined. A line is the last
  resort, drawn with `DMHairline`, and at most one per area.
- **A gesture lives only as long as the view it is attached to.** While a drag
  is held, never reorder views (`ForEach` order) or remove the view that holds
  it. Lift the dragged item with `.zIndex` and keep drag chrome alive with
  `@GestureState` (the Home canvas does this).
- **Never put a `Divider` inside a `ZStack`** — it becomes horizontal and greedy.
  Use `Rectangle().frame(width:1)` / `.frame(height:1)`.
- Numbers shown to the user go through `Text(verbatim:)` with explicit formatting.
  Never `Text("\(intValue)")` — SwiftUI localizes it (pt-BR renders `5.182`,
  `740,31M`). This bug already shipped once; don't repeat it.
- A central page must fill the center (`.frame(maxWidth:.infinity, maxHeight:.infinity)`),
  never float at intrinsic size. Its content uses the whole width too: no
  `maxWidth` cap on a page body (Settings had one, and the owner asked twice
  for it to reach the edge).
- **A running job is a `BGTask` card, never a strip inside a layout.** Whatever
  the app is doing — the workspace sweep, deleting sessions, sending an image,
  adding a subdomain — registers through `AppModel.beginTask/bumpTask/setTask/
  finishTask` and is drawn by `DMToastCard` in the bottom-right stack. A strip
  that appears and disappears inside a `VStack` has no fixed height, so it
  pushes everything below it down and back on every tick; the sidebar's old
  "Connecting…" bar did that on every 60s sweep. A job counted in bytes sets
  `showsCount = false` (the bar alone); while its size is unknown (a folder
  download, packed as it travels) it keeps `total` 0 and puts the bytes so
  far in `detail` (`BGTask.showBytes`). One that ends at once uses
  `dropTask` so it does not blink a finished card. The small
  `ProgressView().controlSize(.small)` inside a panel stays what it is: that
  panel loading its own content, not a job. A `devmachine` run against a
  machine is a machine job instead (see Machine jobs). A widget's own poll is the
  exception: it is the widget's content (see Home widgets).
- **A sheet dims the window under it, corner cards included.** A sheet open
  while a job runs (New scheduled task setting up a workspace) draws the
  cards over itself with `.showsProgressCards()`; the corner leaves them
  out while `sheetsShowingProgress` is above zero.
- **`.clipped()` / `.clipShape` do NOT clip hit-testing.** A `scaledToFill` image
  overflows its container and its invisible overflow still swallows clicks over
  neighboring views (this once killed the sidebar's right edge for a whole day).
  Every decorative full-bleed view (wallpaper, gradients, shadows) gets
  `.allowsHitTesting(false)`. Never rely on clipping to contain hit regions.
- SwiftUI `Button` + `.contextMenu` on the same view in a `ScrollView` fires
  once then goes stale on macOS. Rows use `.onTapGesture` (modifiers via
  `NSEvent.modifierFlags`) + `.contentShape(Rectangle())` + `.contextMenu`.
- Never `makeFirstResponder` on an embedded AppKit view (terminal) during mount —
  it steals focus from SwiftUI and makes sidebar clicks flaky. Focus is
  request-driven instead: an explicit user action (opening or stacking a session)
  calls `TerminalRegistry.requestFocus(_:)`, and the pane hands the request back
  on the next runloop once the view is in a key window (`viewDidAttach`).
- When clicks die "in a region" and nothing looks wrong: dump the AppKit
  hierarchy + `hitTest` from inside the app (walk `window.contentView.superview`,
  log class/frame per view). A platform view wider than its container is the tell.

## Terminals (SwiftTerm)
- `TerminalRegistry` owns ONE live `LocalProcessTerminalView` (mosh or ssh → `tmux new-session -A`)
  per session for the app's lifetime. `TerminalPaneView` only attaches/detaches it;
  single pane and session grid cells re-parent the same view. Never mount the same
  session in two places: two tmux clients at different sizes make `window-size latest`
  flap and garble the screen. Detached views are LRU-capped (6); a dismantled pane
  never terminates the process (only delete/rename/quit do).
- Remote sessions run with `TERM=tmux-256color` (`RemoteCommands.remoteTerm`), never
  `xterm-256color`: the host's `/etc/tmux.conf` gives every `xterm*` client `extkeys`,
  tmux then forwards the kitty keyboard protocol coding harnesses can turn on, and
  SwiftTerm's kitty encoding breaks Enter and dead keys (ç, ´). Check with
  `tmux list-clients -F '#{client_termfeatures}'` on the host: the app's client must
  not list `extkeys`. `LegacyKeyboardTerminalView` also drops the kitty query answer
  and XTVERSION replies as a second guard. Do not "clean this up".
- Terminals run with `optionAsMetaKey = false`: this Mac uses the U.S. layout, where
  Option composes accents (⌥c is ç, ⌥e a is á), and SwiftTerm's default (`true`)
  turns them into `ESC c`. A local key monitor in `TerminalRegistry` flips the flag
  back on for Option+function keys only, so Option+arrow still sends `CSI 1;3D`
  (shell word jump). Verified with synthetic `NSEvent`s, never by typing into the
  owner's live sessions.
- SwiftTerm is pinned by revision (`9fc2d2f`, 2026-09-04: kitty encoding fixes);
  upstream `main` after 2026-09-09 does not link (`MetalError`). Bump on purpose only.
- **One painter per pixel.** The terminal paints its own background at the
  opacity from Settings; the padding around it is four strips beside the
  terminal, never a layer under it (`TerminalContainerView.paintPadding`). Two
  translucent layers over the same pixels can never match a strip that has one,
  and that difference is what read as a border. The strips take their colour
  from `nativeBackgroundColor`, so they follow whatever the program sets.
- **A pane that returns unchanged gets no size change, so nothing redraws it.**
  Switching sessions, closing a page, coming back from the session grid: the program was
  never told anything happened. The app asks explicitly — `tmux refresh-client` for
  a remote session, the window-changed signal to the foreground process group for a
  local one (`TerminalRegistry.requestRepaint`). Do not fake a resize instead: an
  earlier version shrank the pane a row and restored it, which left the last row
  unpainted, and another killed the local client and restarted it, which left the
  keyboard wired to the process that had just died. `refresh-client -t` takes a
  client, never a session: given the session name it only said "can't find client",
  so the command names each client of the session (`RemoteCommands.refreshClient`).
- **A remote pane coming back leaves an idle tmux copy mode**
  (`RemoteCommands.leaveIdleCopyMode`), on return to the pane and when the app
  becomes active or the screen wakes. tmux's `WheelUpPane` enters copy mode
  *without scrolling* when the program does not read the mouse (Claude Code's
  normal view), so one stray wheel-up report leaves the screen looking the same,
  frozen, with every key going to copy mode until Ctrl+C or q. The tell is the
  window name `[tmux]` in the status line, not the program's. Only copy mode at
  scroll 0 with no selection is left; scrolled up, someone is reading. Not focus
  reporting: the hosts run `focus-events off` and mosh drops `?1004`.
  The activation/wake check logs in, so it is rationed
  (`CopyModeCheckSchedule`): tmux runs one server per account, so each
  workspace alias with a pane on screen needs its own login (one login per
  machine cannot reach another account's tmux without root); what is
  limited is when. One ssh at a time, aliases grouped by machine, each
  machine at most once per 5 minutes, never a paused workspace, nothing
  while the sweep runs, and an ssh-level failure pauses through
  `AppModel.noteSSHFailure`, the sweep's own rule (see Performance rules).
- **A process starts only after its pane has the size it will be drawn at**
  (`viewDidSize`). Started earlier it learns a placeholder geometry, and a program
  that repaints only what changed never corrects it.
- **`needsDisplay` never repaints a terminal. Call `requestRedraw()`.** SwiftTerm
  draws through a Metal render loop by default on macOS: `draw(_:)` returns at
  once and frames come from its own driver, so an AppKit invalidation is dropped
  without a word. That is why panes came back blank and a click fixed them — the
  click was the only thing marking a frame dirty.
- Terminal layout is explicit (`TerminalContainerView.layout()`), not autoresizing
  masks — they lost the insets after SwiftUI's first sizing pass.
- **The viewer reads, never writes.** `FileViewerStore` asks for size plus the
  first 2 MB in base64 (`FilePreviewReader.command`), decides in Core what the
  file is (code, markdown, image, binary, too large) and shows it. Highlighting
  stops above 200 KB, where highlight.js blocks the interface long enough to
  look broken.
- **A feature that reads `case .session` only is a bug in waiting.** A session
  runs on a host or on this Mac, and every path has to answer for both:
  the context panel was gated on `.session` and never showed for a local
  session; "maximize" tagged only remote panes and always picked the first cell;
  the file palette and the Files window each had their own version of this.
  Handle both cases of `TerminalKind`/`SidebarItem`, or say in a comment why one
  is out.
- **Never hand a live session a size that is not the pane's.** SwiftUI measures a
  representable with sizes that are not the pane (2 by 1 cells among them), and a
  container starts at a placeholder size; every one of those reaches the program
  as a resize, and a remote multiplexer rewraps its screen and loses characters.
  Sizes are applied only once the pane is in a window, and anything below
  `TerminalSizeGuard` is ignored (`TerminalContainerView.applyContentFrame`).
- **Page keys are swallowed by the terminal.** SwiftTerm answers an unmodified
  Page Up/Down by scrolling its own buffer, which for a session inside a
  multiplexer holds a single screen — so the key does nothing and the host never
  sees it. A remote pane gets the bytes sent explicitly
  (`TerminalKeyboard.pageKeyBytes`); a local pane keeps the terminal's own
  scrolling, which is what it should do.
- **A file sent to a session lands on the machine that runs it** (drop on a
  pane, ⌘V of an image, ⌘K Send file), always through `PaneUploadStore`: the
  original name plus the time before the extension, in the harness folder
  (`UploadStoragePolicy`), never overwriting (`-2`, `-3`, …). The remote name
  travels as base64 and is decoded on the host, so no character of it reaches a
  shell. Paths are typed quoted, without Enter. A folder is refused, not guessed.
- **The pane owns selection, in every session** (`SelectingTerminalView`,
  `TerminalPointer`). tmux turns mouse reporting on in every remote session,
  and SwiftTerm then hands every press, drag and release to it: a drag became
  tmux's yellow copy-mode selection, a click could not clear a selection
  SwiftTerm had made earlier, and the copy depended on the host's config. So
  press, drag and release always go to SwiftTerm's selection (mouse reporting
  off for that call), a plain single click is replayed afterwards for a
  program that reads the mouse, and the wheel keeps SwiftTerm's rule, so tmux
  still scrolls its history. A drag shorter than `TerminalPointer.dragThreshold`
  is a click. Copy on select (Settings → Appearance → Terminal, on by default) copies a drag,
  a word or a line on release; ⌘C with nothing selected leaves the clipboard
  alone. No key is intercepted for selection: SwiftTerm clears it on any key,
  and Esc, ⌃C and the rest reach the program unchanged.
- **A copy made by a program on a host arrives as OSC 52** (tmux's keyboard
  copy mode, an editor's yank). `TerminalDelegateGate` stands in as SwiftTerm's
  delegate, because `LocalProcessTerminalView` answers the clipboard itself and
  does not let a subclass change it: a write is taken only from the focused
  pane and up to `TerminalClipboard.maxWriteBytes`, and a query is never
  answered, so a host cannot read the Mac's clipboard. On the host, the zsh
  package's `~/.tmux.conf` sends `\E]52;c%p1%s;%p2%s\007`: tmux 3.4 sends
  nothing when `%p1` is left out, and mosh forwards only the `c` clipboard.
- **A panel reads through `CommandTarget`, never through an alias.** `HostRunner`
  runs the same command over ssh (in the tmux pane's folder) or here on the Mac
  (in the folder `zmx ls` reports), so Context, Files and Git work for a local
  session. Two commands are not portable and have a local form: `find -printf`
  is GNU only, so a local listing uses `ls -Ap1` with
  `FileTreeParser.parseNames`.
- **A worktree is removed only after a read-only check** (`WorktreeRemoval`).
  The main checkout and the session's own worktree are never offered. Dirty or
  locked needs its own checkbox before `--force` / `--force --force`; a branch
  is deleted only with `-d`, only when merged into the main checkout's branch.
  Paths and branches are single-quoted; the remove runs from the main checkout.
- **A removal reports per worktree, never one exit code.** Single or "Remove N
  merged…", one shell runs the worktrees one after the other and prints a
  record each (`WorktreeRemoval.removeCommand`/`parseRemoval`). `branch -d`
  refusing (its upstream is behind, even when merged into main) keeps the
  branch as a warning; the folder is still gone. A folder already gone counts
  as removed and is pruned, so a second click never fails on it. The batch
  once failed whole on one refused branch, kept its stale list, and the retry
  then failed on every folder it had already removed.
- **"Permission denied" is a refused login only in ssh's own words**
  (`FailureCause.isSSHLoginRefused`: `Permission denied (publickey…)`,
  `…, please try again`, too many auth failures). git and rm say it about a
  file (`fileAccessDenied`), and git exits 255 too, so the exit code proves
  nothing. The worktree sheet names the account and the path instead.
- **Files another account owns stop a worktree remove halfway** (a root
  container's bind mount, a `sudo` build). The check lists up to 10 and a
  count (`find ! -user`). git then drops its record and its `.git` file
  early and leaves the rest: the snapshot lists such folders as leftovers
  (a `.git` file pointing at a dropped record, or no `.git` at all inside
  `<main>/.worktrees`). Only a remote non-self machine, a path inside
  `/home/<user>`, and a second checkbox get "Remove as machine admin…"
  (`WorktreeAdminRemoval`): `devmachine run --machine` runs a script with
  base64 arguments that checks again as root (canonical paths, not a mount
  point, the `.git` proof) before `rm --one-file-system`; the prune and
  `branch -d` run after, as the user. This Mac never deletes as admin; it
  shows the commands. A folder already gone is a "Prune".
- **Hiding a workspace also empties its rows from Stats and the subdomain
  list.** The host is what says who owns a row: a container by the folder it was
  started from (compose or the Supabase CLI writes it, and it lives under
  `/home/<user>`), a port by that container or by the process holding it
  (`Ownership`). What cannot be attributed — a hand-made container, the apex
  site, anything outside a home folder — stays on screen: hiding what has no
  owner would hide the machine itself.
- **A missing tool is not a zero.** A machine without Docker reports
  `docker.available: false`; Stats and Home show "No Docker" / "—" and the
  install commands (`ContainersState`), never "0 Containers". The note the
  stats package puts in `errors` for it is not a failure and is not shown.
- **Hiding a workspace is a list of what to hide, not of what to show**
  (`AppSettings.hiddenWorkspaces`, filtered by `WorkspaceVisibility`). A new
  workspace from the CLI shows up without anyone opening Settings. Everything
  except Settings reads `AppModel.visibleWorkspaces`, so a hidden workspace
  costs no row, no poll and no ssh; hiding also closes its panes at once
  (`TerminalRegistry.closeWorkspace`), which is what ends the mosh it held.
- **The sidebar order is a drag away and forgets what is gone**
  (`SidebarOrder` in `UserDefaults`, key `sidebarOrder`). Workspaces, Local
  included, move as whole blocks; a session moves only inside its own
  workspace (`SidebarDrop` refuses anything else). Anything without a saved
  place goes to the end. Hiding a workspace forgets its place and its
  sessions'. A workspace or session is forgotten only when a list was really
  read without it: a failed CLI read or ssh poll never prunes, or an outage
  would wipe the order. A rename through the app moves the place to the new
  name at once, and polls keep that name for 30 s or until they list it, so
  one landing before tmux renames cannot drop it. Navigation,
  the palette and workspace stacks read the same order as the sidebar.
- **The Local workspace lists what `zmx ls` reports**, merged with what the app
  remembers (`LocalSessionScan.merge`): a session started outside the app shows
  up, and a remembered one that has no shell yet shows without a client count.
  One `ps -axo pid=,ppid=,comm=` per poll detects every registered coding harness.
- **A local pane runs the account's login shell** (`LocalShell`: the user
  database first, then `SHELL`, then `/bin/zsh`), never a fixed zsh: a bash or
  fish user got a zsh with none of their configuration.
- **The prompt turns mouse and focus reporting off** (`ShellIntegration`). A
  program that dies without undoing them (an ssh that drops, an editor killed
  with SIGKILL) left them on, and every mouse move reached the shell as typed
  `35;48;9M…`. zsh gets it through `ZDOTDIR` (its `.zshenv` puts `ZDOTDIR`
  back before the user's files load), bash through `--init-file` (which then
  reads the login files and `.bash_logout` itself, because bash skips an init
  file in a login shell), fish through `-C`. A local session that zmx already
  holds keeps the shell it was started with. Any other shell starts plain. The files live in
  `Application Support/Devmachine/shell-integration`, checked at every pane
  start; if they cannot be written, the shell starts plain rather than without the user's files. zmx
  runs the command only when it creates a session, and needs `HOME` passed:
  bash and fish do not look it up.
- **A local session is renamed in the sidebar only.** `zmx` has no rename and its
  socket is named after the session, so `LocalSession.handle` (the multiplexer
  name, and the registry key) never changes; `name` is what the sidebar shows.

## Remote terminals (mosh, falling back to ssh)
- **The app is the mosh wrapper.** It runs `mosh-server new` over ssh
  (`MoshBootstrap`), reads `MOSH CONNECT <port> <key>` from output that may
  carry login noise, and starts the embedded `mosh-client` (`Contents/Helpers`,
  from `scripts/fetch_mosh.sh`) with the key in `MOSH_KEY`, never in argv.
  Homebrew's `mosh-client` is only the fallback for a local build.
- **`-s` binds the server to the address ssh reached**, so the client aims at
  the same machine: `devmachine resolve` first (detected once per run with
  `resolve --help`), then the `hostname` of `ssh -G <alias>`, looked up here.
- **A pane never hangs on mosh.** Exit 127 (no mosh-server) → ssh at once. A
  mosh-client still showing "Nothing received from server" after 5 s
  (`MoshClientProbe`) is killed with SIGKILL — on SIGTERM it waits for a
  shutdown ack that cannot come — and ssh starts in the same view from
  `processTerminated`, the one moment SwiftTerm lets a view relaunch. That
  ssh kills the unreachable mosh-server first (its pid comes from
  `[mosh-server detached, pid = N]`): otherwise it holds a second tmux client
  for 60 s and the screen flaps.
- **What failed is remembered per machine for the app run**
  (`RemoteTransportMemory`, 30 min, injectable clock). A remembered failure
  is not recorded again (that would push the re-probe back forever) and not
  announced again. An ssh that could not connect at all says nothing about
  mosh and is not remembered.
- Only a started mosh that could not get through shows the pane notice. A
  machine without mosh-server is a choice; the badge's tooltip says why.

## Previews
- The context panel's Preview tab lists the selected workspace's published
  sites and the ports its user listens on (`PreviewTargets`, from `expose list`
  and the stats `ports`); a local session lists what this Mac listens on
  (`lsof`). Nothing polls it: it draws from the cache on show, reads only
  what is past its TTL, and reads everything on Refresh.
- Where a preview or a context-panel link opens is one setting
  (`AppSettings.linkOpening`, default browser); ⌥-click flips it once.
  `PreviewStore` is the only place that decides.
- A workspace port is reached through `devmachine tunnel --local`, spawned and
  owned by `TunnelManager`: reused per workspace and port, held by the tabs (or
  the browser) that use it, stopped when the last one lets go and on quit. The
  local port is the remote one when free here, else any free port. The CLI
  binds 127.0.0.1 only.
- The in-app browser loads http(s) and `about:blank` only (`PreviewURLPolicy`),
  keeps `target=_blank` in the same tab, and uses one non-persistent data
  store per app run. The address bar shows the web view's real URL.
- **The terminal and the pane beside it are one split** (`DocumentSplitView`,
  `DocumentSplit` in Core). The pane's share is a fraction, saved only when a
  drag ends (`DocumentSplitState`); each side keeps 320 pt, nothing else caps
  it; a double-click on the divider goes back to half and half. Every
  `ResizeHandle` drag is measured in `.global` coordinates: measured in the
  handle's own, each step moved the origin of the next and the pane shook.
- **Maximize lays the pane over the terminal, which keeps its width**, so the
  program inside gets no resize and comes back as it was; the keyboard moves
  to the page. ⇧⌘↩ is the preview's while its page has the keyboard
  (`FocusedPreview`), and ⌘W then closes that tab instead of ending the session.
- **The pane's tab strip is a plain row, never a horizontal `ScrollView`.**
  Inside the scroll view a click on a tab's close mark hit-tested to its
  `NSClipView` and never reached the button (checked in a demo build with
  events sent through the window: no close with the scroll view, a close
  without it). Long titles are shortened instead. Middle click, the chip's
  menu and ⌘W close a tab too.
- **A preview tab belongs to the session it was opened in**
  (`PreviewTab.owner`, set from `AppModel.selection`). Each session shows its
  own tabs and selected tab; ending, removing or hiding a session closes its
  tabs, and a rename carries them over. Tunnels are held per tab, so one
  shared by two sessions stops with the last tab. The split width stays global;
  maximize is dropped on a session switch.
- The in-app browser sends the system Safari's user agent (`SafariUserAgent`,
  version read from Safari's bundle): WebKit's default lacks `Version/… Safari/…`
  and Google served its page for an old browser. A tab's name follows the page
  (`PreviewTitle`: its title, else its current host).
- **A `WKWebView` is the engine, not the browser.** Everything Safari's own
  window does for a page is `PreviewPage`'s job, and a missing delegate
  method fails silently: a file input did nothing, `alert` vanished,
  `confirm` was always false. So the page answers file inputs (`NSOpenPanel`),
  `alert`/`confirm`/`prompt` (sheets naming the asking origin), Basic and
  Digest logins (a sheet; the credential lives in the non-persistent store's
  memory for the run, never written or logged), camera and microphone (asked
  per origin, remembered for the run; `Info.plist` carries both usage strings
  and the entitlements both device keys, since macOS kills an app that
  touches either without them), downloads, popups, fullscreen video and Web
  Inspector (`isInspectable`, right-click → Inspect Element). Every question
  goes through `PreviewPrompting`, so tests and the `preview-browser` walk
  answer them without a window.
- **Only the main frame's own address is limited** (`PreviewURLPolicy.navigation`).
  Subframes load anything but `file:`; `about:`, `blob:` and `data:` are the
  page itself (an iframe's `srcdoc`, a generated file) and blocking them
  broke iframes, downloads and apps. `file:` and `javascript:` in the main
  frame are refused with a notice; any other scheme (`mailto:`, `tel:`, a
  meeting app) is offered to the app that opens it, after a yes.
- **A popup is a tab, with a real web view.** `window.open` and
  `target="_blank"` get a `WKWebView` built from the configuration WebKit
  hands over, so `window.opener` works and OAuth or payment popups can post
  back; the tab opens beside its opener in the same session (`.opened`), and
  `window.close()` closes it. `javaScriptCanOpenWindowsAutomatically` stays
  off: WebKit then lets only a click, or a script answering one, open a tab.
- **A download lands in ~/Downloads, never over a file** (`DownloadName`,
  `FileTransfer.freeName`, the Files tab's `-2`, `-3` counter), from a
  `download` link, an `attachment`, or a type WebKit cannot show; the Files
  tab's own `TransferNotice` card says where, with Reveal in Finder. A demo build saves to `DEVMACHINE_PREVIEW_DOWNLOADS`.
- **Browser keys belong to the page that has the keyboard**
  (`PreviewWebKitView.performKeyEquivalent`): ⌘F find, ⌘G / ⇧⌘G next and
  previous, ⌘= / ⌘− zoom, ⌘0 actual size (Home only when the page does not
  have the keyboard). Esc is never taken; it closes the find bar only from
  inside its field. WebKit's "Open Link in New Window" reads "New Tab".

## Home layout
- **The default Home board is laid out for the canvas it opens on**
  (`DefaultBoard.make(harnesses:canvasWidth:machines:)`). `HomeCanvasView`
  opens the board only once the canvas has a width, so a missing `home.yml`
  is written for the real window; 1280 is the fallback. Every machine sits
  side by side in one row at the top (sized from `MachineStatsCard.width` and
  `MachinesWidgetView`'s spacing, for the machine count `StatsStore` knows, 3
  when none), one `devmachine-app/usage` per enabled harness under it (two
  across from two harnesses, 336-480 wide), and on the right edge a 336-416
  column with the clock and the summary pill under it. Machines, usage and
  the summary are `size: auto` (no `h` in their frame): they are as tall as
  their content. `DefaultBoard.layout` also gives the height it reserved for
  each one (machines: its rows; usage: 600, because the full card with a
  typical snapshot measures 591 at any width; summary: 160) so the rows under
  them are spaced; those heights only space the stored `y`, and the push-down
  (below) fixes any overrun on screen. The clock stays fixed. The pill sits at
  the top of its widget so it reads as part of the clock.
  `DefaultHomeBoardTests` pins the frames; `DefaultHomeBoardFitTests` draws the
  real cards against the reserved heights. The `HomeLayout` notes below
  describe the pre-widget view.
- **`HomeLayout.plan` decides from Home's width alone**; showing or hiding
  the sidebar only changes that width. The clock sits in the middle of all of
  Home when, there, it still clears the cards column by the gap
  (`HomeClockPlacement`, Core, with the clock's width estimated at 2.8 times
  its scaled point size); otherwise in the middle of the column beside the
  cards. Its height never changes: it is laid across the same row.
- **The button that reopens a collapsed sidebar floats over the centre**, so
  Home moves its cards (stacked: everything) down until they start below it
  plus a gap (`FloatingButtonClearance`, Core). ContentView measures the
  button in its `window` coordinate space and hands it down as
  `\.collapsedSidebarButtonFrame` (nil while the sidebar shows); HomeView
  measures itself in the same space. It once covered the first card's name.

## Coding agents (`harness` in code)

The UI and prose say **coding agent** (Settings → Coding agents, "Show
coding agent icon…", the widget field "Coding agent"). Code and JSON keep
`harness` (`CodingHarness`, `HarnessID`, `harnesses`).

- **Detection never depends on the toggle.** Every harness in
  `HarnessRegistry.builtIn` is detected, badged, gets its icon, upload folder
  and Context panel, enabled or not and whether or not its CLI is on this Mac:
  many run only on a server. Enabling one only adds it to the launch choices
  and session defaults (and its usage card), and never needs its CLI here.
- **Identifying a harness and activating it are different.** Identification
  (icons, Context, process matching) covers every harness in the registry
  and never looks at packages. Activation is the Settings → Coding agents switch,
  shown only for a harness whose `HarnessDescriptor.packageName` (the
  workspace package that installs it: claude-code, codex, pi, antigravity,
  opencode, kimi-code, cline) is in the pinned release's
  `packages list` (`CodingAgentPackages.activatable`; before the list is
  read, the declared name is trusted). Any other harness shows its row with
  no switch, and its saved on/off is left as it was. New workspace's
  Coding agents group offers only the packages of harnesses turned on
  (`CodingAgentPackages.choose`), hides the others and what needs them
  (claude-plugins needs claude-code), and with none on says so and links to
  Settings → Coding agents. The first run's skills picker is unrelated: it offers what
  `skills add --agent` accepts (`SkillAgent`). Views never name a package.
- **A harness on without its CLI on this Mac starts on remote workspaces
  only** (`LaunchPlace`): it is offered in the remote fallback, the
  per-workspace defaults and a remote workspace's new-session menu and ⌘K
  commands, never for Local. A Local default naming one starts a plain
  shell (`HarnessSettingsFacade.localSessionProgram`), the way a harness
  turned off does, and its Settings row says "Not on this Mac — remote
  workspaces only". Whether a CLI is here comes from `CLIAvailability`:
  looked up (a missing one costs a login shell) off the main thread at launch
  and when Settings opens, then cached; only a read before the first lookup
  ends pays for it itself.
- Local has one Terminal-or-coding-agent default (Settings → Coding agents →\n  Session defaults → Local). Remote workspaces inherit one
  remote fallback and may override it individually.
- Remote choices are declarative. Never probe or modify a VPS to validate a
  harness; its shell reports a missing command when the session starts.
- Session badges, launch commands, process matching, upload storage, context
  support, and usage capabilities come from adapters/facades. Views do not
  switch on Claude, Codex, executable names, or provider colors.
- Home stacks one usage card per enabled harness that has a usage provider
  (Claude, Codex; the others have none). A harness whose CLI is not
  found still gets its card, showing "CLI not found", so Home never disagrees
  with Settings. The CLI is looked up on every read: inherited PATH, known
  directories, then the login shell's `command -v` (mise/asdf/nvm installs an
  app opened from Finder cannot see); Codex runs with its own directory first
  on PATH so an npm `#!/usr/bin/env node` script finds `node`. The
  menu-bar Usage tab uses one column for one harness and two columns for two;
  the Pull Requests tab remains 420 points wide.
- Codex usage reads `account/rateLimits/read` and `account/usage/read` through
  `codex app-server`. It never calls `thread/start` or `turn/start`, so the
  refresh does not start a model turn or consume inference tokens.
- Sidebar coding agent icons (Settings → Coding agents → Sidebar, off by default) are files in
  `Resources/HarnessIcons/`, loaded by name (`HarnessIconLibrary`): a new
  harness gets its icon by adding a file. `<HarnessID>.svg` is always the
  monochrome drawing in `currentColor` (it takes the row's tint, and every
  built-in harness must have one); `<HarnessID>-color.svg` is the optional
  brand-color version. Settings → Coding agents → Icon style
  (`AppSettings.harnessIconStyle`, `.color` by default) picks it: Original
  colors uses `-color` when it exists, else the monochrome file; Monochrome
  never reads `-color`. A `-color` name is never a harness id. No monochrome
  file → no icon, the hover dot stays. A session with no harness at all shows
  the `apple.terminal` symbol in the same slot. Brand colors exist for Claude,
  Codex, Antigravity, Kimi and Herdr; Pi, opencode and Cline are black and
  white anyway.
  Claude, Codex and Pi come from Orca (MIT, `LICENSE-orca.txt`); codex-color,
  Antigravity, opencode, Kimi and Cline from lobe-icons (MIT,
  `LICENSE-lobe-icons.txt`); Herdr from its own repo (Apache-2.0,
  `LICENSE-herdr.txt`). A new icon names its source in one of those files.
- **Herdr is a harness with no package.** It is the runtime agents run in,
  not an agent: a session that started `herdr` is known by it and gets its
  icon, but it has no Settings switch (`packageName` nil), no skills option
  and no Context reader.
  `DEVMACHINE_DEMO_ICON_STYLE=monochrome` switches the `harness-icons` demo walk.
- The Context / Files / Git panel belongs to every selected session. Unsupported
  provider context shows an empty state while Files and Git remain available.
- **Context reads a harness through one `ContextHarnessReader`** (Core,
  `ContextRoots.readers`, the one table): it finds the project's sessions,
  newest first, and reads one into a `ContextHarnessPass`. Each reader loads its
  own storage: JSONL per session (Claude, Codex, Pi, Kimi, Antigravity), a JSON
  file listed in SQLite (Cline), or rows in one SQLite file (opencode). SQLite
  is opened `mode=ro` (never `immutable=1`, which misses rows still in the
  WAL); a locked or missing database reads as no sessions. `ContextFacade`
  serves every harness in the table, local or remote: the remote
  `devmachine-infer` answers with the same ids. A harness is detected by exact
  program name (`pi` is never `pip`); the session's detected harnesses pick the
  transcript before the newest-file fallback.
- **A remote pane is matched by every program under it, not only the one in
  front.** tmux names the foreground program, and Cline's npm launcher is
  `node`; the native `.cline` it starts is a child. So the session listing
  (`RemoteCommands.listSessions`, still one ssh per poll) also returns each
  pane's pid and the host's `ps -A -o pid=,ppid=,comm=`, and
  `TmuxListParser` walks the pane's descendants with
  `ProcessTree.matchingPrograms`, as the local scan does. Bare `node` matches
  nothing. tmux runs last in that command: its exit code is the command's,
  and 127 is how a host without tmux is told apart. Without a process table
  the pane's own command still counts.

## Window toolbar
- The main window keeps a unified toolbar (`.windowToolbarStyle(.unified(showsTitle: false))`)
  only for its height: macOS then places the window buttons with more room.
  Never move them by hand. The bar is see-through (`titlebarAppearsTransparent`,
  set by `WindowButtonsReader`), so each mode's own surface runs up under it
  and Home's wallpaper reaches the top edge.
- The sidebar toggle (`SidebarToggleButton`, ⌘B) is drawn over the band, on
  the window buttons' line, read from where macOS put them
  (`WindowButtonsReader`): at the sidebar's right edge while it is open, right
  after the buttons while it is closed (`SidebarTogglePlacement`). A toolbar
  item cannot follow the sidebar's edge.
- The sidebars run under the band. Their title row keeps the same space under
  the window buttons as the New row keeps before the list
  (`SidebarHeaderSpacing.blockGap`; change that one constant and both move). The `.clipped()` sidebar takes
  `SidebarUnderTitlebar` outside the clip, or the header is cut off. A
  terminal starts below the band only while the sidebar is closed; Home always
  runs under it.
- Demo frames capture the window's frame view (`SnapshotChrome.capturedView`);
  the window buttons come out grey (the window is never key) and are painted
  again where the window put them (`SnapshotChrome.measure`).

## Scroll bars
- The app always uses the thin overlay scroll bar that shows only while
  scrolling, in every window: `ScrollBarStyle.apply()` runs first in the app's
  `init`, before any window exists, and puts `AppleShowScrollBars =
  WhenScrolling` in the argument domain. That domain ranks above the system's,
  so it wins at launch and after every System Settings change or mouse
  plug-in (AppKit re-reads the same key). No view sets a scroller style.
- `DEVMACHINE_DEMO_SCROLL_BARS=Always` registers "Always" below it, standing
  in for that System Settings choice; `DEVMACHINE_DEMO_WALK=scroll-bars`
  renders views that scroll (Code, the Files tab, the Files window, the file
  viewer, Settings, Chats) to check that none draws a track.

## Right panel
- The context panel (Context, Preview, Files, Git) runs under the
  see-through title bar like the sidebars (`SidebarUnderTitlebar`); its tab
  row is centred on the window buttons' line (`\.titleLine`, from
  `SidebarHeaderSpacing.line(buttons:)`), the same line as the sidebar
  toggle. The collapsed strip's icon sits on that line too.

## Chats
- **The engine is `devmachine chat`; the app only draws.** One process per
  message (`chat send`, `chat ask`), NDJSON `started/text/tool/denied/done/error`
  (`denied`: a tool claude refused because `-p` cannot approve it, drawn
  "Blocked: <name> needs approval")
  (`ChatEventDecoder`, Core). stdout and stderr share one pipe, so a line that
  is not an event is kept only as the failure's details. `ChatProcess` reads
  the pipe to the end before it returns: `StreamingProcess` could hand the last
  line over after the exit, and the turn then read as failed. Each turn carries
  a token (`ChatStore.turns`): the previous turn's process may report its end
  after the next turn started, and only the current turn may end it.
- **Warm sessions.** A message goes through a long-lived `chat session`
  (`chat ask --serve` for Ask) when it can: `{"type":"send"}` lines in,
  `ready`, the same turn events, and `closed` out (`ChatSessionLine`, Core).
  `ChatSessionPool` keeps one warm session for the next new chat (started
  when the quick panel or the new chat page shows, replaced when its harness,
  workspace or MCP changes), one per open chat (the CLI ends it after 10 min
  idle) and one per visible Ask section. A turn ends on `done`/`error`, not on
  the exit; Stop writes `cancel`; quit closes every stdin. A session that dies
  mid-turn fails the turn and the next message opens another. A CLI that
  refuses the command or a flag before `ready` is older: the turn goes out
  again with `chat send` and sessions stay off until relaunch. Tests and demo
  never start one (`ChatCommandRunning.openSession` throws by default).
- **Status.** `{"type":"status","stage","message"}` lines (connecting,
  reading the transcript, starting, loading MCP, waiting) set
  `ChatConversation.status`, drawn muted beside the cursor in the pane, the
  quick panel and Ask; the first `text`/`tool`/`denied`, `done`, `error`, a
  stop or the exit clear it. A send into a warm session that is still starting
  shows that session's latest start-up status; into a ready one, "<Harness> is
  thinking…" until the CLI's `waiting` (not for Ask, which reads the
  transcript first and says so). An older CLI sends none and nothing is
  made up. VoiceOver hears each status once, as a low-priority announcement.
- **MCP.** Chats start without MCP servers, hooks and plugins (`chat.mcp`
  off); the chip (`ChatMCPChip`) is kept per chat as the record's `mcp`, and
  `--mcp`/`--mcp=false` goes out only when it differs (`ChatMCP.flag`).
- A new chat is listed at once under `pending-<uuid>` and moves to the CLI's id
  on `started` (`ChatStore.current`). A process that ends with no `done` or
  `error` is a failure (`ChatConversation.processEnded`); `unknown command
  "chat"` is an older CLI (`needsNewerCLI`, the card offers Update the CLI);
  a usage error (`error: …` and no NDJSON) is `refused`.
- **Where chats run belongs to the CLI** (`chat.default_workspace`,
  `chat.folder`, `chat.harness` via `config set|unset`, read from
  `--format json config show`), so a chat from a terminal lands where one from
  the app does. The app keeps only the shortcut, the menu bar rows and the
  harness switches (`AppSettings.chats`). Read only is fixed and never a setting.
- **Code, Chats or Schedule** (`AppModel.appMode`, ⌘1, ⌘2, ⌘3): the sidebar's
  title is the switch ("CODE WORKSPACES ▾" / "CHAT WORKSPACES ▾" /
  "SCHEDULE ▾"; native menus in real use, `ChatMenuCard` only in demo frames,
  `SidebarModeHeader`), with refresh and close at the right of that row and
  "New session" / "New chat" under it. Chats replaces the main row; picking a
  session, a page or Settings goes back to Code. In Chats, a dot by the title
  says a session in Code waits for the person. Pickers are drawn in the view
  (`ChatMenuCard`), not `NSMenu`, so a demo frame shows them; they lock after
  the first message (a chat keeps its harness and workspace).
- **Quick panel**: `QuickChatPanelController`, a non-activating `NSPanel`
  opened by a Carbon `RegisterEventHotKey` (no Accessibility permission),
  default ⌃⌥Space. Tests hand `QuickChatHotkeyController` a fake registrar;
  nothing registers a real hotkey under XCTest or in demo mode. Recording a
  new shortcut in Settings suspends the old one. The panel has no SwiftUI
  `.help`: AppKit asked SwiftUI's tooltip bridge for a tooltip while the
  panel resized under a streaming answer, and the bridge read a view that was
  already gone (EXC_BAD_ACCESS in `TooltipResponder.text`, App v0.7.3). Views
  in `Chats/` and `Components/` use `.dmHelp(_:)`, which the panel turns off
  with `dmShowsHelp`; `DMHelpGuardTests` fails on a plain `.help` there.
- **Ask** (`app.ask`, provider `app/session-ask`, engine 1.8, after Links in
  the default Context tab): `AskStore` keeps one thread per session
  (`AskSessionKey`); a session on this Mac passes its folder. "Clear" (shown once a
  thread has messages) runs `chat delete` on that thread and starts a new one,
  so it does not come back after a restart; a refused delete keeps the thread
  and says why under it. Clear waits while an answer is coming. Ask chats left
  in the CLI's store from before Clear deleted (only the newest shows) are
  never deleted on their own: after a restart the next one shows, and Clear
  removes it too.
- Demo walk `DEVMACHINE_DEMO_WALK=chats` (`DemoChats`): the 14 screens of the
  approved mockups drawn from the real views over invented chats.
  `DEVMACHINE_CHAT_E2E=<devmachine binary>` runs `ChatCLILiveTests`: a real
  chat with the local claude in a temp configuration.

## Operator session
- **The Operator is the local session in the CLI's configuration folder**
  (`Workspace.operatorSession`, path `AppSettings.opsRepoPath`). Every way
  in (sidebar click, ⌘K `go.operator`) goes through
  `AppModel.openOperatorSession`, which decides with `OperatorLaunch.plan`
  (Core): a shell the multiplexer already holds (`zmx ls`) or a pane already
  started is only shown, never typed into.
- **Every start asks**, not only the first: once the shell has exited
  (`exit` inside it), the next open shows a central page
  (`AppPage.operatorChooser`, `OperatorChooserPage`) with one
  `DMPictureChoice` per harness whose CLI is on this Mac
  (`HarnessSettingsFacade.installedHarnesses`, turned on or not: the point is
  finding out what you have) and "Terminal only". The pick is saved as
  `operatorProgram` and starts the session; the next chooser shows it
  selected (`last`). Settings → Coding agents → Session defaults → Operator
  session changes that selection. A saved harness whose CLI is gone is
  offered as "Terminal only".
- **Only the first pick** (`operatorProgram == nil`) asks the harness what
  the folder is for: Claude Code and Codex get `HarnessPrompt.operatorIntro`
  as their positional first message (`SessionStartup.asking`, shared with
  Packages' "New package"), any other harness starts plain. Later picks start
  the program plain; asking the same question on every start is noise.
- **No harness installed: the terminal opens and nothing is saved**, so the
  chooser shows once one is installed. Settings written before this decode
  as not chosen, so an existing Mac sees the chooser once too.
- **Settings → General → Enable Operator session** (`operatorSessionEnabled`,
  on by default and for older settings). Off filters it out of
  `AppModel.localSessions` after the multiplexer merge, which empties the
  sidebar row, ⌘K's `go.operator` and the per-session palette item; Save
  leaves it for Home if it was open (`applyOperatorVisibility`). Its shell is
  never killed: turning it on again shows the same session.
- Demo walk `DEVMACHINE_DEMO_WALK=operator`: `200` the chooser over the demo
  Mac's CLIs, `201`/`202` General with the switch on and off (the sidebar
  without the row), `203` the Operator's program in Settings → Coding agents, `204` the chooser
  again with Codex as the last pick.
  `18-operator` selects the Operator directly: through the click it would
  show the chooser.

## Performance rules (learned from a 2 GB footprint)
- Poll only while a view is visible (`onAppear`/`onDisappear` begin/end, refcount),
  one in-flight run per target, publish a `@Published` only when the value changed.
- Never decode an image or run a blur inside `body`; bake once (`WallpaperBackground`)
  and cache with a cap. The network map wallpaper is drawn, not baked: its
  canvases are `Equatable` views, repainted only when the map or the size changes. Hidden `.opacity(0)` views still cost a full-window drawable —
  render only what is shown. No `.shadow` on full-window cards.
- Session polling is a sequential sweep, one ssh at a time: parallel auths against a
  locked agent got this Mac banned by fail2ban. Keep it that way. A failure pauses
  only what it is about (`PollPause`, `AppModel.pollPauses`), so one broken workspace
  never stalls the others: a refused login pauses that workspace for 5 min, doubled
  for each refusal in a row up to 30 min (fail2ban
  counts failed logins per source IP on each machine; another account's working login
  adds nothing); a second workspace refused on the same machine inside that pause
  pauses the whole machine for 5 min, so a locked agent costs at most two refused
  logins per machine per pause. An unreachable machine pauses its own workspaces for
  1 min (only that workspace when the machine is unknown), a refused host key pauses
  nothing. A paused
  workspace gets no automatic login at all: sweep, selection poll, context, Git, copy
  mode check, the mosh watchdog's ssh. Try again and opening a session try once; the
  sidebar's refresh button (`refreshAllNow`) lifts every unreachable pause and sweeps,
  but leaves refused logins paused; a
  refusal pauses again (a refused mosh-server login skips the ssh fallback, which would
  be a second refusal). The sidebar shows each pause under the workspace
  (`PollPauseSidebarCard`, one per machine when the machine is paused) and it clears on
  the next answer; a corner toast says it once, when the pause starts, not again while
  it only goes on.
- **A workspace no sync has created is never asked.** `packages.lock` names every
  workspace a sync applied; one it does not name has no account yet, and every login
  to it is a failed one (`AppModel.awaitsFirstSync`). It shows "isn't set up on its
  machine yet" and is asked again when the lock names it, or on Try again. A lock
  that names no workspace (an older CLI) and a workspace that has answered before
  hold nothing back. The CLI reports a refused login as `login-refused`, which is
  `SSHFailure.authDenied` here, never `unreachable`.

- Machine stats are the one app-wide poll, because Home shows them: `StatsStore`
  reads every non-self machine every 90s, staggered, one run per machine, backing
  off 90s → 3m → 5m on errors, paused while the Mac sleeps. The last good snapshot
  per machine lives in `Application Support/Devmachine/stats-cache.json`, so Home
  and Stats draw from it at launch; the skeleton shows only when there is no cache.

## Local-first machine data
- Everything read from a machine goes through one `DataCache` (Core,
  `LocalFirst/`), shared as `DataCache.shared`: memory plus
  `Application Support/Devmachine/machine-cache.json` (memory only under
  XCTest). Keys live in `MachineDataKeys`: `workspaces`, `sitesContext`,
  `sites:<machine>`, `dnsProviders:<machine>`, `dnsRecords:<machine>|<provider>|<zone>`,
  `sessions:<alias>`, `context:<target key>`. TTLs are per kind
  (`CachePolicy.standard`: ports 45s, sites 60s, DNS 5 min).
- A view draws the cached value at once and never waits on a fetch when one
  exists; `revalidate` refreshes in the background only what is stale,
  invalidated or forced (the Refresh button). One fetch per key at a time;
  every other caller joins it. A skeleton shows only with no cache at all;
  an old value shows its age (`DMAgeLabel`).
- An answer is laid over the list on screen by identity (`StableList`): an
  equal answer publishes nothing, and a reorder alone keeps the rows still.
- Ports are the stats poller's: `StatsStore.freshSnapshot` reuses its
  snapshot, or one read through its schedule (never during a backoff). No
  view runs its own `stats` ssh.
- A publish or removal invalidates that machine's `sites` and `dnsRecords`
  and reads them again; the Preview tab hears it through `DataCache.observe`.
- A session's Context warms its workspace (`WorkspaceMachineData.warm`), so
  Publish a port… and Preview open with something to show.

## First run (onboarding)
- **Onboarding owns the window until the Mac is set up or skipped**
  (`AppModel.launchRoute`): Home needs saved settings and the CLI (or a
  remembered "Skip for now"). A first run never lands on Settings.
- **The first run is the Add machine wizard, not a second implementation**
  (`OnboardingFlow`, a pure state machine driven by `OnboardingRunner`).
  The CLI is installed first, as a background step with its log
  (`MachinePlanStep.installCLI`: the release binary, never Homebrew),
  because the wizard reads keys and packages through it. Then
  `AddMachineWizardView` runs with `firstRun`: "Do you already have a
  server (VPS)?" (yes: address, login, key or password, `machines scan`
  fingerprint confirmed against the console; no: a Lima machine on this
  Mac, no address asked), packages, review of the exact commands, run.
  `firstRun` always syncs, always adds `devmachine-app` (essentials needs
  it, but `installed_on` lists only what a machine names itself), asks for
  the first workspace (`MachineWizard.requiresWorkspace`; a switch,
  `skipsWorkspace`, turns it off) so the app opens with one in the
  sidebar, and installs the skills (below). A Mac already connected
  but missing `devmachine-app` gets `packages add` + `sync` per machine,
  run the same way. A CLI older than `MachineUnattendedAdd` says so and
  offers the installer (`.cliTooOld`).
- **No agent setup.** The setup is deterministic and all in the UI: no
  "let your agent do it", no prompt, no "ask the agent". The owner's agent
  once hand-rolled a Lima VM with `limactl`, which the checklist can never
  see.
- **Every step is a background process with its log** (`MachineStepRunner`,
  `DMLogView`): no pane, nothing typed. Retry resumes from the failed step;
  the ones done are skipped (`machines add` is atomic on CLI 0.7.27+). A
  run that ends 0 but leaves the Mac as it was is `unresolved`, with Check
  again, never a loop. Demo mode refuses every run (`OnboardingDemoTests`).
- **The skills always install** when a harness is chosen: one
  `skills add --agent <h>… --yes` after the sync (`--agent` works for a
  harness not installed yet). The choices are the harness registry's
  harnesses that the CLI accepts (`SkillAgent.options`, which maps a
  `HarnessID` to its `--agent` name): claude, codex, pi and opencode on any
  CLI, antigravity, kimi and cline on 0.7.28+ (an older CLI refuses the
  whole command on an unknown agent). A new harness is offered once it is
  in `SkillAgent.cliAgents`. Preselected: Settings → Coding agents plus the
  harness folders this Mac has (`AddMachineModel.harnessesInUse`). A failed skills step is a warning
  with Retry (`MachinePlanStep.blocksSetup`), never a blocker for "Start
  using Devmachine".
- **A machine on this Mac installs Lima when it is missing**
  (`LimaInstall`, `LimaInstaller`): GitHub's latest release tarball for
  the Mac's processor, checked against the release's `SHA256SUMS` before
  a byte is written, unpacked into `~/.local` (`bin`, `share`, `libexec`);
  the temporary tarball is deleted whether the unpack worked or not.
  The CLI runs `limactl` by name, so `~/.local/bin` goes first on the PATH
  it gets. A failed download offers `brew install lima` when Homebrew is
  there. Only an unattended run (CLI 0.7.27+) can do this; an older CLI
  still shows `brew install lima`.
- **Every failure says how to fix it** (`SetupFailurePanel`,
  `SetupFailureHelp`/`SetupFailureAdvice` in Core): a cause read from the
  log (an outdated Xcode, a download, Lima's checksum, a changed host key,
  a refused login, an unreachable server) gets its own steps and buttons;
  anything else gets what the step ran, the last lines, Retry and Change
  answers. Every failure also has Report a bug (`DMReportBugButton`): the
  browser opens a new GitHub issue filled in by `BugReport`, with secrets,
  addresses, paths, emails, fingerprints, the typed hosts and domains, and
  the user, machine and workspace names (whole words, any length) taken
  out, under 7000 characters. The app never posts it. The
  DNS setup's failure has the same button.
- Demo walk `DEVMACHINE_DEMO_WALK=setup-flow` (`DemoSetupFlow`): `80`–`91`
  are the setup (start, CLI install and its failure, choice, server and
  local details, packages, review, running, failed, ready, old CLI),
  `92`–`95` Settings → General.
- **It ends on "Start using Devmachine"**: `completeOnboarding` reads the CLI
  again, fills the empty General fields, saves them and opens Home, with
  no restart. Settings → General shows what the CLI reports read-only
  ("Change…", "Edit"), re-reads it each time it opens, and an issue the setup
  fixes (no CLI; a folder other than the CLI's own with no `config.yml`)
  carries a button back into onboarding.
- **Leaving onboarding reads the CLI once, off the main thread**, and hands
  that answer to the workspace load. Then `onLeftOnboarding` reloads the
  machine lists (Home's stats machines, `MachinesStore`, readiness), so a
  machine the setup just added shows without a relaunch. The config
  folder watcher is made again on any check while the folder it watches
  did not exist when it was made (`isWatchingConfiguration`).
- The main window opens at 80% of the screen when AppKit has no saved frame
  for it (`MainWindowSizing`, read before any window exists); a saved frame
  always wins. Demo walk: `DEVMACHINE_DEMO_WALK=setup-flow`.

## Machine readiness
- **A machine missing `devmachine-app` gets a card, never a gate over the
  whole window** (`MachineReadinessStore`). Declared comes from `packages
  list`, applied from `packages.lock` in the CLI's config folder
  (`PackagesLock`), and a failed package call (`PackageCallReports`, posted by
  `DevmachineCLI`) overrides both until the lock changes. Anything unread
  fails open: no card.
- **Prepare syncs with `--tags devmachine-app` only** and only on CLI 0.7.24+
  (`MachinePrepare.minimumCLIVersion`). A plain sync would apply every change
  waiting in the configuration behind a button that says Prepare, and an older
  CLI's tagged sync wrote the whole plan into the lock. Never move the
  packages pin from the app: it is shared by every machine.
- **A new workspace on a machine without `devmachine-app` is one sidebar
  card, not two** (`SessionProblem.mergesIntoFirstSync`): its account and the
  package both wait for the first sync, so the card says
  `devmachine sync --machine <m>` instead of offering Prepare, which would fix
  only the package. Home keeps the machine's own card. Demo shot `79`.
- **A session list never fails silently** (`SessionListProblem`): ssh looking
  the alias itself up as a hostname means no Host entry, exit 127 means no
  tmux. Neither stops the sweep or pauses polling; both show in the sidebar
  with the fix.
- The CLI's config folder is watched (`ConfigDirectoryWatcher`), so a machine
  or workspace added in a terminal shows up without a restart.

## Home widgets
- **Home is `<config>/boards/home.yml`, nothing else.** `<config>` is what
  `devmachine --format json config path` answers (`DevmachineCLI.configPath()`,
  called by `HomeBoardController.start()` off the main thread; it honours
  `DEVMACHINE_CONFIG`), never `AppSettings.opsRepoPath`.
  The app, `devmachine widgets add/remove` and agents edit the same file.
  `BoardStore` reloads it on every change. The app never creates the config
  folder: with no folder, nothing is written.
- **The CLI writes by rename, so `BoardFileWatcher` watches the `boards/`
  folder.** A watch on the file alone goes blind after the first CLI write,
  because the rename swaps the inode. The file is watched too, for editors that
  write in place. Bursts settle for 150 ms, so one save is one reload.
- **What is on disk wins.** A write waits 300 ms (`BoardStore.writeDelay`) and
  is dropped when the file changed since the store last read it: the CLI's
  edit replaces the app's pending one. An invalid file keeps the last good
  layout on screen, the banner names the line, and nothing is written until it
  is valid again: someone is fixing it by hand. An edit still waiting when the
  file turns invalid is dropped, and the last good layout comes back. Reset is
  the one write allowed then: it saves `home.yml.bak` first. With no config
  folder it writes nothing, keeps the placements and shows an error.
- **A failed `widget-placements.json` save is not silent.** The placement
  stays in memory, the error goes to the `widgets` log and to
  `HomeBoardController.placementsError`; the next good save clears it. If the
  CLI's config path is unknown at launch, the next reload asks again.
- **Yams reads, our code writes.** Three writers produce the file (the app, the
  CLI, a person or agent), so the reader must accept any YAML style. A
  hand-made parser would call valid files invalid, and that blocks every write.
  The writer (`BoardCodec.encode`) stays ours because the spec fixes the key
  order and the flow-style `frame`. It quotes text with the rules in
  `YAMLScalarStyle.swift`, kept compatible with the CLI's `yaml.v3`. Cross-writer
  tests guard that: change the quoting and they fail.
- **The golden fixture is the CLI's file.**
  `Tests/DevmachineCoreTests/Fixtures/widget-contract-1.7.json` must stay
  byte-identical to `internal/widgets/testdata/contract.json` in the CLI repo.
  Change one, copy it to the other. `widgets schema --json` prints the same
  document re-indented, so the live test compares it as sorted-key JSON.
- **Frames are points at 100% text size** (`CanvasLayout`). The canvas
  multiplies by the text scale to draw and divides to store, so the file reads
  the same at any setting. A window smaller than the layout moves widgets in on
  screen only.
- **A stored `x` is a place on Home with the sidebar open**
  (`CanvasLayout.aligned`). With the sidebar hidden the canvas is wider, and
  `HomeCanvasView` draws each widget from the sidebar-open width to the real
  one: widgets that touch (8 pt or less apart) move as one group, a group
  within the margin (24 pt) of an edge stays at that edge, any other keeps its
  share of the free space between the margins (a centred group stays centred).
  The rule is its own inverse when the groups are the same, so a drop with the
  sidebar hidden aligns back from where the widgets are drawn, before clamping
  and push-down, and stores the x of the dropped widget's whole group: a widget
  dropped beside a group joins it, and the group keeps its place on screen.
  With the sidebar open nothing moves.
  The file format did not change: the CLI rejects unknown keys in a board.
- **A widget is as tall as what it shows (engine 1.7).** A view with
  `"grows": true` in the contract (summary, machines, harness usage, text,
  number, status, list, markdown) has a natural height; the others (clock,
  gauge, sparkline, web, terminal, pull-requests panel, usage panel) do not.
  The rules are `CanvasLayout`, pure and tested:
  - `size: auto` on Home, with `frame: {x, y, w}` and no `h` (`BoardWidget.isAuto`;
    `frame.h` is 0 in memory, and the encoder writes nothing). A written `h` next
    to `auto` is read and dropped. Without `auto`, `h` is required
    (`<id>: frame needs h unless size is auto`); `auto` on a view that does not
    grow is refused with the sidebar's own message (`BoardCodec` for an inline
    widget, `WidgetResolution` for a typed one).
  - Drawn height = `auto ? content : min(content, max(h, 40))`
    (`drawnHeight`). A stored `h` on a growing view is a **cap**, never a
    floor: an old `custom` 160 pt summary draws at its pill. A growing view has
    no preset height minimum (one `stack_row`, 40 pt, when set by hand); its
    minimum width is the smallest preset width. Other views keep today's minimum.
  - The content height is measured by the view, not guessed. `WidgetChromeView`
    draws an `auto` widget with `hugs: true` (every growing view then reports
    its natural height: no `maxHeight: .infinity`, no `ScrollView`, no
    `GeometryReader`; machines draw every card, list every row) and reads its
    size with `onGeometryChange`. A widget with a cap draws in its box as
    before and keeps an invisible hugging copy only to learn the content
    height. `HomeCanvasView` stores the measure per id in board points; it is
    never written to the file. **Never give a hugging view `size.height`:** it
    would feed the last height back as the next offer and the widget could
    never grow.
  - **Push-down is display only** (`CanvasLayout.pushedDown`). Widgets are
    taken by stored `y`, then `x`; a widget's drawn `y` is `max(stored y,
    drawn bottom + 8 of every earlier widget whose columns overlap)`. It never
    pulls up, and stored frames do not change until the person moves the
    widget. A widget dragged is not pushed while it is held.
  - **Resize**: width as before; for a growing view the stored `h` is the
    height drawn at release, `min(dragged, content)`; within one snap (8 pt) of
    the content the entry becomes `size: auto` (`resizedGrowing`).
    The "..." Size picker lists Auto first for a growing view.
  - **Reset size** ("..." menu, and a double-click on the resize corner)
    returns a growing widget to `auto` at the width of its `default_size`, a
    fixed one to its `default_size` preset (`CanvasLayout.reset`,
    `HomeBoardController.resetSize`).
  - New widgets (gallery, `WidgetPlacer.newInstance`, inline
    `InlineEntryPlacement`) and the default board are `auto` for a growing
    view. The spot search cannot measure, so an `auto` widget occupies the
    height of its `default_size` (inline: 160), as the CLI's `widgets add`
    does.
  - `ImageRenderer` does not lay out a `ScrollView`, so the natural-height
    tests (`WidgetAutoHeightFitTests`, `DMFitCheck`) draw the `hugs: true`
    views, which have none.
- **A widget's meaning comes from the CLI catalog** (`widgets list --format
  json`, `WidgetCatalogStore`). The app ships no `widget.yml`. An entry the
  catalog cannot resolve keeps its place as a placeholder, so a missing
  package never loses a layout. `DemoData.widgetCatalog` is for demo
  screenshots only.
- **`places` adds a widget once.** `widget-placements.json` in Application
  Support (`WidgetPlacementsFile`) remembers it, so a removed widget does not
  come back. Placement is generic (`WidgetPlacer.place`): a widget that
  places itself and has one single-value `choice` input is placed once per
  option of its source, and the placements file keys each copy
  `<type>#<option>` (for usage: `devmachine-app/usage#claude`). A usage
  widget is placed only for a harness turned on in Settings, and never for a
  harness the board already shows (the default board's `devmachine-app/usage`
  entries, or an older `claude-code/usage` or `codex/usage` entry).
- **Stats keep their own schedule.** A widget never starts its own `stats`
  ssh; it reads `StatsStore`. Usage refreshes per harness on the widget's
  interval. A minimized widget, or one scrolled out of sight, refreshes
  nothing.
- **Compatibility fails open.** `WidgetAppManifest.current` names the CLI and
  packages release this build needs. The corner card shows only when one is
  readable and older. A `dev` CLI is never "behind". Newer releases are the
  update toasts' job, not this card's.
- Test hooks: `DEVMACHINE_CLI=<binary>` runs another CLI,
  `DEVMACHINE_WIDGET_PLACEMENTS=<file>` moves the placements file, and
  `DEVMACHINE_DEMO_BOARDS=<folder>` keeps a demo board across restarts.
- **A widget written in the board runs only after "Allow".** An inline
  `command`, `prompt` or `session` widget (the contract's `approval: true`)
  shows `WidgetApprovalCard` until the owner allows it. The decision is kept
  by SHA-256 (hex) of the canonical JSON (keys sorted, no spaces) of what
  runs, taken at run time with the area's real context
  (`ApprovalSubject.hash(for:context:)`): kind, run/script/args, shell,
  target, harness, prompt, permission mode (only when set, so older approvals stay valid), session, and for `shell: true` the `DM_` values it
  reads (only the `$DM_CONTEXT_<KEY>` the line names is exported and hashed) — never `every`, `timeout`, `mode`, `keep` or `parse`. The card and
  the stored summary read `ApprovalPrompt`, built from that same filled
  source and `DM_` values, so the owner approves exactly what the hash
  covers, never the raw templates. The runner
  checks the hash again right before every run (`SourceApprovalGate`). It
  lives in `Application Support/Devmachine/widget-approvals.json`, never in
  the config folder: whoever can write a board must not be able to approve
  it. Any change to what runs asks again; Deny pauses and keeps the widget,
  with "Allow" to change your mind. Every area keeps its own copy of the
  decisions, so a decision is merged onto what the file holds now
  (`WidgetApprovalsFile.record`, read, change, atomic write), never saved
  from the stale copy, and then announced (`WidgetApprovalsFile.didChange`,
  object = the file URL); every `WidgetSourceController` on that file
  reloads and runs what was allowed. An unreadable file means everything
  waits again. A package widget asks only when its package is third-party
  (see Package providers and third-party widgets); `url` and app providers
  never ask.
- **A value is never part of a shell line** (`ArgvBuilder`, the one place a
  widget argv or shell line is built; templates are filled once, at run
  time, with the area's real context). `shell: true` takes no templates in `run` and
  no `args`: the line reads its values as `$DM_INPUT_<NAME>` and
  `$DM_CONTEXT_<KEY>` environment variables. Without `shell`, templates go
  only in `args`, never in `run`: the program is named in `run`, found on the
  PATH here and started directly — never through `/usr/bin/env` or a shell,
  which would read a value-like word as an option or as code. Prompts run
  `claude -p -- <prompt>` and `codex exec --skip-git-repo-check -- <prompt>`
  (the `--` keeps a prompt that starts with `-` from being a flag).
- **A widget on a machine or workspace runs only through `devmachine run`**,
  with the argv of the CLI plan's Appendix B: `--machine` before `run`,
  `--workspace` after it, `--no-log`, then `--argv -- <words>` (a shell line
  is `--argv -- /usr/bin/env NAME=value … /bin/sh -c <line>`, each pair one
  word) or `--package <p> --script <s> -- <args>`, or, for a package
  provider, `--package <p> -- <command> --<key> <value> …`. `--config` is never passed:
  the process inherits `DEVMACHINE_CONFIG`. The app never opens its own ssh
  for a widget. stdin is `/dev/null`; exit 255 is "never ran" with the CLI's
  last `error:` line; exit 1 with `unknown flag` and no stdout asks for a
  newer CLI. `target: local` runs on this Mac in the home folder, with the
  known tool folders added to PATH (`LocalPATH`), `/bin/sh -c` for
  `shell: true`.
- **One run in flight per widget; polls only while Home is on screen.**
  `SourceSchedule` runs a poll on its interval (floors: command and url 5s,
  session 2s, prompt 15m; prompt defaults to manual), a manual widget only on
  ▶, and a stream only while it is on screen and not minimized. Hiding,
  minimizing or removing it, or leaving Home (`onDisappear` →
  `WidgetSourceController.stop()`), sends SIGTERM, and that exit is never
  shown. A stream that ends on its own waits for ▶. A timeout or more than
  1 MB of output ends the process; the last good value stays with the error
  beside it. Demo mode never runs a source.
- **A widget poll is not a machine job.** It draws in its own card and never
  registers a `BGTask` or a `MachineJobCenter` job (unlike sync, Prepare and
  the other runs against a machine).
- **Session widgets read, never type.** A remote session is
  `tmux capture-pane -p -e`, a local one `zmx history <session> --vt`; the
  terminal view is a parsed `AttributedString`, not a SwiftTerm view. A click
  selects the session (workspace or local); a machine's admin session is not
  clickable.
- **Web widgets** share one non-persistent `WKWebsiteDataStore` for the app
  run (not the preview browser's), allow http(s) in the main frame only, open
  no popups, and reload on `every` only while the view exists. The address
  comes from `URLSourceRunner.address(of:context:)`, the fill a `url` fetch
  uses; one that is not http(s) shows its error in the card, never a blank page.
- **Inline entries are written back as they were read** (`YAMLTree`: flow or
  block, quoting kept), in the order `id, title, source, view, sizes, fits,
  frame, size, minimized, z`, byte-identical to the CLI's writer; a
  cross-writer test (`testAnInlineWidgetSurvivesARewriteByteForByte`) guards it.
- **Unit tests never run a widget for real**: no real CLI, no ssh, no
  network, no real config folder, Application Support or keychain — fakes
  and temp folders. The one exception is opt-in:
  `DEVMACHINE_WIDGETS_E2E=<binary>` runs `WidgetSourceLiveTests` through that
  CLI against a temp config whose only machine is `here` (`self: true`, this
  Mac), with `DEVMACHINE_KEYCHAIN=off`. It never targets a remote machine.
  The same variable runs `StackBoardLiveTests`, `MenubarBoardLiveTests` and
  `WidgetEditLiveTests`.

## Sidebar widget stacks
- **The sidebar and the Context tab are boards.** `<config>/boards/sidebar.yml`
  and `<config>/boards/context-sidebar.yml`, same envelope and store rules as
  `home.yml` (`StackBoardStore` = `BoardFileStore<StackBoard>`: disk wins,
  300 ms write, an invalid file is never written over, reset keeps `.bak`).
  `surface:` must match the file. A stack entry has no `frame` and no `z`;
  its place is its index. Optional `size` is a preset (its rows × `stack_row`
  40 pt) or `auto` for a view that grows (since engine 1.7 that includes the
  generic views text, number, status, list and markdown and the canvas app
  views summary, machines and harness usage; on `auto` a source widget or a
  canvas app view draws with `hugs: true`, as tall as its content, the same
  rule as on Home); with no `size` it draws `auto` when
  the view grows, else the widget's `default_size`, its first size, or
  `medium` (`StackLayout.effectiveSize`). A widget the app adds (gallery or
  placement, `StackPlacer.newEntry`) is written with that size, `auto` or
  the preset, as `devmachine widgets add --board` writes it, so the YAML is
  the same whoever added it. `collapsed: true` draws the header
  only and runs nothing. Key order on write: typed `id, type, with, size,
  collapsed`; inline `id, title, source, view, sizes, fits, size, collapsed`;
  `size` only when set, `collapsed` only when true. Inline `source` and
  `view` are written back as they were read, byte for byte.
- **A row's width is the scroll view's content width, never the scroll
  view's own** (`StackBoardView` measures the `VStack` inside the
  `ScrollView`). A row pinned to the scroll view's width is wider than its
  content area by the scroller; a row with a fixed height hid that, but one
  that hugs its height (`auto`) made the panel 15 pt wider on every layout
  pass and hung the main thread.
- **The default boards are today's UI** (`DefaultStackBoard`): `[workspaces]`
  and `[shortcuts, publish-port, monitors, shells, sub-agents, todo,
  pull-requests, links]`, every entry `type: devmachine-app/<id>`,
  `size: auto`. The CLI starts from the same boards when a file is missing.
- **Wrap, never rewrite.** The nine app views (`WorkspacesWidgetView`,
  `PublishPortWidgetView`, `ContextSectionWidgets`, `StackAppWidgetView`) hold the old SidebarView and ContextPanel code,
  moved as it was. Change them as you would have changed the old code; never
  "clean them up" into new layouts: selection, ⌘/⇧-click, `SidebarOrder`
  drag, host-key and readiness cards, row menus and the add-machine button
  live there. Shortcuts and Publish a port scroll with the rest; at offset 0
  the panel looks as it did.
- **The sidebar never empties.** The nine `devmachine-app/*` widgets resolve
  built in (`AppStackWidgets`) when the catalog lacks them; a catalog entry of
  the same name wins, and the stack gallery lists them even while the
  catalog loads or failed (`WidgetGalleryContent`, failure line above the
  list). With no config path the default board draws in memory,
  read-only. An invalid file on first read draws the default read-only under
  a `DMBanner` naming the file and line (the last good layout once one was
  read); nothing is written until it is valid.
- **The chrome stays out of the way** (`StackRowModel.showsControls`). A
  widget with its own section header (shortcuts, monitors, shells,
  sub-agents, todo, pull-requests, links) shows grip, chevron and ⋯ in that
  header's trailing slot (`StackHeaderControls()`) on hover. The workspace
  list and Publish a port have no header, and a pill there would cover the
  first workspace's buttons, so their pill shows only while the pointer is
  over them **and ⌥ is held**. Any other widget gets a `StackTitleHeader` with
  the controls always shown. The "Add widget" row is always in the layout, at
  the end, drawn (and hit-testable) only while the pointer is over the panel.
  An app widget with nothing to show (no pull requests, no links, a section
  before the first read, Shortcuts with no session, Publish a port with no
  Caddy) takes no space at rest or on a plain hover, as before; only while
  ⌥ is held over the panel (the `.bare` rule) does it draw
  `StackEmptyWidgetHeader`, its title row with the controls, so it can still
  be collapsed, moved or removed (`StackRowModel.showsEmptyHeader`).
- **One session-context section leads** (`ContextSectionLead`): before the
  first read, the board's first expanded one draws the status view; after
  it, the first that draws something carries the age label.
- **A header drag freezes the list.** While the grip's drag is held the rows
  come from a snapshot (`StackBoardView`'s `StackDrag`), the dragged row
  lifted by `.zIndex` and offset; it lands by the neighbour it crossed
  (`StackDragMath`, `StackDropTarget`) and the order is written once, on
  release. Never reorder or remove the view holding a live drag.
- **Context keys, every one set, empty when unknown.** Sidebar: `selected`
  (the selected workspace, `SidebarContext`). Context tab (board\n  `context-sidebar`): `machine,
  session, workspace, path, repo, branch, harness` (`SessionContextFacts`,
  built by `ContextBridge` from the selection, `ContextState`, readiness and
  the self machine). `session` is the tmux session or the local session's
  name; `machine` is the workspace's machine, or the self machine for a local
  session; `path` is `ContextState.cwd`, else the local session's folder.
- **`repo` and `branch` cost a probe, so they run only when read.**
  `ContextGitProbe` (`git rev-parse --abbrev-ref HEAD` and
  `remote.origin.url`) runs through `HostRunner.runCapturingWithFolderArgument`
  (the folder is `$1` after `cd --`, never spliced into the line), only
  while an expanded widget reads `repo` or `branch`
  (`StackBoardController.needsGitContext`). It probes on a new session or
  folder, on each new session-context read (`ContextState.updatedAt`, so a
  `git checkout` shows), and when the Context tab appears, keeping the last
  answer meanwhile. A new read probes at most once per 30 s for the same
  session and folder (`GitProbeThrottle`); a new session or folder, or the
  tab appearing, probes at once. A failure is retried on the first read
  30 s later, not sooner. No timer of its own (`ContextGitStatusStore`).
- **A session switch hands over its context once per widget**
  (`ContextPushGate`). While the new session's first context read is out,
  the board keeps the old keys. While only the git probe is out (judged by
  the key about to be probed, not the store's last one), every other key
  goes at once with `repo`/`branch` pending
  (`WidgetSourceController.setContext(_:pending:)`): a widget that reads a
  pending key (`ResolvedSource.reads`) keeps its last context and output and
  does not run until the probe answers; the rest run at once. So no widget
  runs on an empty `path` or `branch` first, no approval card flashes, and a
  hung ssh holds only the widgets that need git.
- **A context change stops what it touches.** A widget whose read values
  change is stopped, what it showed is cleared (it belonged to the other
  session; sparkline history stays) and its approval hash is taken again: an
  inline widget asks again for each new set of resolved values, by design. A
  widget reads only the keys its templates or `$DM_CONTEXT_<KEY>` variables
  name (`ResolvedSource.reads(contextKey:)`); an inline `shell: true` line
  gets and hashes only the `DM_CONTEXT_` values it names; an inline `script`,
  whose text the app never sees, reads them all. A package widget reads the
  keys it declares.
- **Allow and Deny count only for the hash the card showed**
  (`WidgetSourceController.approve(_:hash:)`): if the context moved on, the
  card redraws with the new values and asks again. A source widget waiting
  for approval or denied takes at least `StackLayout.approvalRows` (5) rows so
  the card's buttons fit.
- **Who runs when.** Sidebar widgets run while the sidebar is open
  (`isVisible: !sidebarCollapsed`; SidebarView stays mounted at width 0);
  the context board's while the Context tab is on screen. A collapsed widget
  runs nothing. `ContextStore` keeps its 5 s poll only under
  `ContextPollRule` (panel shown, not collapsed, Context tab, a target, and
  an expanded widget reading `app/session-context`, or an expanded source
  widget reading `path` or `harness`, which come from the same poll:
  `StackBoardController.needsSessionContext`).
- **Placements are saved per surface** (`WidgetPlacementsFile.save(_:surface:)`):
  Home and each sidebar rewrite only their own set. A placements file that
  does not decode moves to `widget-placements.json.broken`, the move is
  logged, and the save goes on with a fresh file. If that write then fails,
  the error itself names where the broken file went
  (`cannotWriteAfterSettingAside`), so the move is never lost.
- **Controllers start from `ContentView.onAppear`**
  (`StackBoardController.startAll()`), never from a view a test can render,
  so rendering `ContextPanel` in a test never asks the CLI anything. No test
  reads `StackBoardController.sidebar` or `.contextSidebar`.
- Test hook: `DEVMACHINE_WIDGETS_E2E=<binary>` runs `StackBoardLiveTests`
  against a temp config the test makes itself: the schema equals the
  fixture, and the CLI's `validate`, `move` and `remove` on an app-written
  `context-sidebar.yml` keep an inline entry byte for byte and refuse a
  `frame`.

## Choosing and editing widgets
Engine 1.7. One mechanism for every widget, on Home, the sidebars and the
menu bar; the app has no code for a particular widget's choices.

- **A `choice` input declares its list.** `inputs.<name>: {type: choice,
  from: machines|workspaces|harnesses, many: bool}`. The widget menu shows
  "Choose ..." for each one (`ChoiceInput.all(of:)`, title from its summary),
  and `WidgetChoiceView` draws a checklist (many) or a picker (one). Options
  come from `WidgetOptionSources` (`StatsStore.machines`,
  `AppModel.visibleWorkspaces`, `HarnessUsageStore.states`), the one place
  that knows the sources; tests hand it closures. Never add a menu item or
  a view that names a widget or an input.
- **Saving a choice.** `WidgetChoiceModel.save` returns a
  `WidgetChoiceOutcome`: `.saved` closes the chooser, `.refused(message)`
  keeps it open and shows the message. It asks the board first
  (`WidgetEditTarget.problem(with:for:)`), then applies.
- **Many: empty means all.** No value, `[]` or every option ticked writes
  no `with` key, so a machine added later shows too. A chosen name the
  source no longer has stays in the chooser as "(not found)" to untick; the
  widget just draws nothing for it. One: no value means the first option,
  decided by the view (`UsageHarnessChoice`).
- **Lists in `with`.** `BoardScalar.list`, written flow (`[main, here]`). A
  template reads it joined with commas; an app provider gets the list in
  `ResolvedWidget.listArguments`. The codec reads the shape; resolution
  refuses a list for a single input and a scalar for a many input, with the
  CLI's words (`InputShapes`).
- **Overrides.** A typed entry may carry `title` and `every`
  (`EntryOverrideRules`): `every` never goes below the provider's, source
  kind's or package provider floor, a stream takes none, and a widget that
  reads an app provider takes no `manual` (it runs on a schedule). Inline
  entries own their title and source, so `every` there is refused. Key
  order: `id, type, title, with, every`.
- **Every edit replaces one entry.** The chooser and the editor build an
  `EntryEdit` and hand it to the board's controller (`WidgetEditTarget`:
  Home and every `StackBoardController`), which writes through the store:
  the 300 ms rule, disk wins, nothing while the file is invalid. Other
  entries stay byte for byte, and an inline source or view the edit did not
  change keeps its YAML tree.
- **An edit is refused only for a problem it adds.**
  `problem(with:for:)` compares the entry's resolution before and after the
  edit. A widget that was already refused (a missing package, say) can still
  change its title; the edit is blocked only when it makes the entry worse
  or names an input the widget does not declare.
- **The editor writes YAML and reads it back.** `InlineWidgetForm` (Command,
  URL status, Web page, Prompt, Session; only Command and URL status in the
  menu bar) writes a one-entry board with one field per line, reads it with
  `BoardCodec` and the area's resolver, and puts each problem under its
  field. An inline widget the templates cannot show edits its title only.
  `TypedEntryForm` edits a package widget's title, inputs and `every`.
- **Approval is unchanged.** An edit that changes what runs (command,
  arguments, target, prompt, session) asks again; title and `every` never
  do (`WidgetEditApprovalTests`).
- **A prompt's permission mode comes from the contract.**
  `PromptSource.permissionMode` holds the harness's own name, nil for its
  default; `PermissionModes` is the only code that reads the contract's
  `permission_mode` field (names per harness, the `dangerous` list, the
  CLI's two messages). `ArgvBuilder.prompt` turns it into the harness's
  flag (Claude `--permission-mode <m>`; Codex `--sandbox <m>`, or
  `--approve-for-me` / `--dangerously-bypass-approvals-and-sandbox`), and
  no mode keeps the old argv byte for byte. The mode is in the approval
  hash, the card names it, and a mode with no checks shows a red line.
  Such a mode never runs on a timer: the reader refuses it, an `every`
  override refuses it, and the Prompt form sets Every to manual and
  locks it. Never write a mode list in Swift: the picker reads
  `InlineWidgetForm.permissionModes()`.
- **Sheets on Home and in the sidebars, in place in the menu bar.** A
  sheet or nested popover from the `MenuBarExtra` window is not reliable, so
  the menubar Edit mode swaps its body for the chooser or the editor.

## Package providers and third-party widgets
- **A package provider is `<pkg>/<command>`** (`PackageProviderName`; `app/*`
  stays the app's). It is `WidgetSource.packageProvider`, kind `provider`,
  output token `json`: any view that takes `json` draws it with
  `{{json.<path>}}`. App providers keep `.provider` and `AppWidgetProviders`;
  a package provider runs through `WidgetSourceController` like a command.
- **It runs only on a machine or workspace, only through `devmachine run`**:
  `--machine <m> run --no-log` or `run --workspace <w> --no-log`, then
  `--package <pkg> -- <command> --<key> <value> …`. `target: local` is refused
  by the reader and again by `PackageProviderRunner`. The CLI's `commands`
  gate applies (the `Call` path, not `--script`).
- **`ArgvBuilder.packageProvider` is the only builder.** `with` pairs go in
  sorted key order; a key must match `[a-z][a-z0-9_-]*`; a value is always one
  argv item, even empty, starting with `-` or holding shell syntax. A value
  holding NUL is refused. The name holds no template. Never route it through
  the shell-line builders, which drop empty words.
  `ArgvBuilderTests.testAPackageProviderValueIsAlwaysOneWordAfterItsFlag`
  guards it.
- **Output is one JSON object** holding every `returns` field without `?`.
  Anything else (a list, two documents, nothing, a missing field) is an error
  and the last good value stays. `every` is ≥ the provider's `min_every`
  (floor 5s) or `manual`; `timeout` defaults to 30s, at most 10m.
- **A package widget reads only its own package's providers.** A catalog
  widget of `acme-tools` naming `mine/load` is refused, whatever the CLI let
  through.
- **Trust comes from the catalog** (`widgets list` `trust`): `official` and
  `local` run as before; `third-party` (a package with
  `.devmachine-source.yml`) asks before any code-running widget (`command`,
  `prompt`, `session`, package provider) runs. An older catalog without
  `trust` reads `release` as official, anything else as local. Each of these
  reads as third-party: an unknown or unreadable `trust` word, a
  `package_source` with no `trust`, and a widget `provider` key that does not
  read as a provider spec. An inline package-provider widget always asks.
- **No package-provider widget written in a board runs before a catalog
  loads.** Until then it resolves to `.waitingForCatalog` ("Waiting for the
  widget catalog…"): no job and no Allow button, so no approval without the
  package commit can be stored. Once the catalog loads it gets its trust and
  commit from the top-level `providers` map.
- **A failed catalog reload marks the kept catalog stale** (`isStale`).
  Third-party catalog widgets that run code, and every inline package-provider
  widget whatever its trust (a stale catalog cannot vouch for it), then wait
  as above until a read works, as the commits it holds may be older than what
  `packages update` installed. Official and local catalog widgets and `url`
  widgets keep running.
  While it is stale, the shared `WidgetCatalogStore` reads `widgets list`
  again on `CatalogRetrySchedule` (30s, 60s, 120s, then every 5 min): one
  pending retry for Home and both sidebars, stopped by a good read, a seed
  or app quit (`stopForQuit` also drops the quit observer, as `deinit` does;
  nothing retries after it). A failed first read (no catalog yet) is retried
  the same way, but only while some board holds a `.waitingForCatalog` widget:
  each controller reports it (`setWaitsForCatalog`) when it syncs its jobs, and
  the retry stops once no board does. Only with no catalog does a board report
  start a retry, so a board sync during a stale spell never moves the backoff
  ahead. With no CLI it settles at every 5 min.
- **The provider index is complete only when a packages release was read**
  and `providers` is there, as `widgets validate` decides it. Without a
  release an unknown package is left to `devmachine run`; a package the
  catalog lists still refuses a provider it does not declare.
- **A third-party hash carries the package commit** (`package_commit` in the
  canonical JSON, even when empty), so `packages update` to a new commit asks
  again for every such widget. That holds for a catalog widget (its
  `package_source`) and for an inline widget naming a third-party provider
  (the commit comes from the catalog's top-level `providers` map). Inline
  widgets of other providers and official/local hashes are unchanged from
  engine 1.2, so no stored approval was lost.
- **Never pass a complete provider index into `BoardCodec`.** The board
  reader checks only shape, target and the 5s floor (`PackageProviderIndex
  .unknown`); the catalog check runs later, in `WidgetResolution`, and refuses
  only that one widget. In the reader, a provider the catalog does not know
  is a `BoardProblem`: the whole board falls back to its last good layout and
  nothing on it can be written until the provider appears.
- **The card says where the code comes from**: "From a third-party package:
  <url>" (selectable) replaces the "written into <surface>.yml" warning, at
  every density.
- `DEVMACHINE_WIDGETS_E2E=<binary>` also runs `PackageProviderLiveTests`: the
  real CLI must take the argv against a temp config (self machine `here`,
  nothing synced) and answer "not installed", never "unknown flag".

## Host keys
- **ssh refusing a host key is its own problem** (`SSHFailure.hostKeyRejected`,
  from ssh's own words on exit 255). No login was tried, so it counts toward
  no ban: the sweep goes on, polling is not paused, and the workspace is not
  painted offline. The sidebar shows one `HostKeySidebarCard` per machine,
  whether or not old sessions are still listed, and a click on one of those
  sessions opens the review. The 5s selection poll skips the alias; the 60s
  sweep still tries it. Only ssh's abort line ("Host key verification
  failed") counts: the CHANGED banner alone can precede a real login.
- **Review → `AppModel.showHostKey(machine)`, a sheet (`HostKeySheet`)** over
  whatever screen asked for it (sidebar card, a refused session's click,
  Settings → Machines' Host key, ⌘K), never a page: the screen under it stays
  as it was, and Close (Esc) or Done goes back to it. It cannot close while
  the trust is writing. `HostKeyStore` runs `devmachine
  machines trust <m> --check --format json` (CLI 0.7.24+; an older CLI
  refuses a changed key without JSON and gets the update advice) on every
  visit, never from a remembered answer: a Lima VM writes a new key on every
  restart. The sheet
  shows both fingerprints and the CLI's `verify` command for the machine's
  own console, never over SSH. Demo walk: `DEVMACHINE_DEMO_WALK=host-key`
  (`DemoHostKey`, `150`–`153`).
- **The trust button stays off until the pasted console output holds the
  exact presented fingerprint** (`HostKeyTrust.confirms`), and the write
  passes `--expect <fingerprint>`, so the CLI refuses if a second scan meets
  a different key. It writes only the CLI's local `known_hosts`, never the
  machine.

## Publishing feedback
- `expose add` / `expose rm` run with `--format json` (CLI 0.7.21+): the
  result (`applied`, `status`, `note`) and the exact stderr drive
  `PublishProgress` (Core). The card (`PublishJobCard` on `DMJobCard`) sits
  in the corner stack: steps, then Live with Open/Copy, Saved with the
  reason, or `DMErrorStateView` with the CLI's stderr and Retry. An older CLI
  without JSON reads as Saved, saying it cannot tell.

## Tests never spawn ssh
`~/.ssh/config` maps `*-devmachine` to the real host, so a fixture alias such as
`acme-devmachine` logs into the VPS as the Mac user. `ProcessRunner` refuses
ssh/mosh/mosh-client/scp under XCTest; tests inject a fake `CommandRunner`.

## A test that blocks must let go
A fake that holds a call (`BlockingRunner`, a semaphore gate) holds one of
Swift's cooperative threads, and a CI runner has only as many as it has cores
(3 on `macos-15`). Three held calls left behind stopped every later
`Task.detached`, and ~80 unrelated tests timed out in the release job while
passing on a 12-core Mac. `BlockingRunner` opens itself when each test ends;
a new gate must be released the same way. To check, run the built bundle with
one thread: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 xcrun xctest
.build/debug/DevmachineAppPackageTests.xctest`. (Not through `swift test`:
SwiftPM itself then hangs.) Only the tests that need two calls in flight at
once may fail there.

## Verifying UI
- Screenshot flow: `./scripts/install.sh` (relaunches), `osascript` to front the app,
  `screencapture -x -R<x,y,w,h>` of the window, downscale with `sips` before reading.
- Never send keystrokes into the app while the owner's sessions are open: `⌘K` +
  typing has landed in his live Claude sessions twice. Verify with screenshots,
  `tmux list-clients`/`capture-pane` over ssh, or ask him to try.

- **`ImageRenderer` does not lay out a `ScrollView`.** A snapshot of a view whose
  body scrolls comes back with the chrome and an empty middle, which reads as a
  bug that is not there. Snapshot the header and the state, and check scrolled
  content in the running app.

## Website videos
- `scripts/site_demo_videos.sh <dir>` runs `DEVMACHINE_DEMO_WALK=site`
  (`DemoSiteWalk`) hidden, then writes `<scene>.webm`, `<scene>.mp4` and
  `<scene>-poster.webp` for the home-page loops (operator, sessions, cli,
  context, publish, scheduled, share, home, quickchat, chats, ask). Each opens on its own subject, with no click
  first, at a reading pace: 0.5 s pointer moves, ~15 typed characters a second,
  a second after each change and labels on screen for at least two seconds.
  The walk writes numbered frames per scene at 1600×1000 and a
  `frames.ffconcat` with each frame's hold; `SITE_DEMO_FRAMES=<dir>` re-encodes
  frames already written.
- Every frame is a real app state from demo data. The walk's only setters are
  demo-only: `DemoData.transcriptOverride` (a terminal fed step by step),
  `DemoContextOverride` (the context panel moving along) and
  `SessionShareStore.seedDemo`. The Share sheets are drawn into the frame
  where macOS shows them, since a sheet is a window of its own.
- A bitmap capture has no pointer, so the walk draws the system arrow onto
  its frames (`DemoPointer`): it eases to the control a state comes from,
  shows a shrinking ring for the click, and stays there. Controls mark
  themselves with `.demoClickTarget(id)`, which records their frame only
  while a demo walk captures (`DemoClickTargets`). Short captions are drawn
  the same way (`DemoPointer.drawLabel`), one at a time. Home's drag and
  resize move the real board frame step by step; the "Add a widget"
  popover is drawn under its button. A right-click's menu is
  not drawn: an `NSMenu` is a window the capture never sees.
- A frame's `zoom` names a control the camera eases to (`DemoCamera`, 0.8 s,
  1.8x), by cropping the real frame; a scene with any zoom is captured at 4x
  so the zoomed text stays sharp. `SITE_DEMO_SCENES="context"` renders one
  scene. The context scene's Links rows come from the app's own extraction
  (`contextExtractRefs` + `contextMapLinks`) over the demo transcript.
- `quickchat` draws the quick panel alone over a gradient desktop
  (`desktopView(for:)`), since the real panel is a window of its own. A
  default-walk screen with `zoom` (`27-ask.png`) is cropped the same way,
  then scaled back to the window's 2x size; a screen may set its own
  `windowSize`. A zoom on Ask (`zoomsReachingThePane`) widens to the session
  pane's left edge, and that session gets a transcript that fills the pane,
  so the terminal beside Ask shows output instead of empty rows.
- `cacheDisplay` does not catch `NSProgressIndicator`'s animation, so a
  spinner is one still frame; Home's board is written again for the walk's
  window, since the one written at launch was laid out for a smaller one.

## Build / test
- `swift build` and `swift test` must be green before every commit.
- Package a bundle with `./scripts/package_app.sh` (writes `build/DevmachineApp.app`);
  `./scripts/install.sh` builds, installs `/Applications/Devmachine.app` and relaunches.
- `scripts/check-real-data.sh` runs as a pre-push hook with the private pattern list
  in `~/.config/devmachine-app/private-patterns`.

## Git
- Conventional Commits, one line, ENGLISH. Sign via the 1Password agent socket:
  `export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`.
- **NEVER add any Claude/AI attribution, trailer, or `Co-Authored-By` — anywhere.**
- Branch prefix `da-` when not committing straight to `main` locally.

## Updates
- The updater replaces this app. For the CLI it runs one of the
  `CLIUpdateCommand` forms and nothing else: `update --cli-only` (CLI
  0.7.23–0.7.30, the binary only), `update --no-machines --format json`
  (CLI 0.7.31+: the binary, then the new binary pins the newest packages
  release and updates the skills on this Mac) or `update --no-machines
  --skip-cli --format json` (the packages card). The packages pin and the
  skills are the only things beyond the binary it may change, on purpose:
  a CLI updated from the app or brew kept an old pin and old skills, and
  nothing said so. **It never changes machines**: never plain `update`,
  never `sync`, never `--yes` or `--machine` (`--no-machines` refuses
  both), never the configuration. A CLI too old for `--cli-only` gets the
  command (`CLIUpdateAdvice`) in a `DMCommandBlock`: never run it, never
  type it into a session.
- The JSON forms print the report on stdout and the log on stderr, so
  `ProcessCLIUpdater` keeps stdout apart (`StreamingProcess.run(separatesStdout:)`)
  and `CLIUpdateReport` reads it. The CLI prints the JSON even when a step
  failed, then exits non-zero; the app shows the stderr `error:` line.
- **A newer CLI gets its own corner toast** (`CLIUpdateBanner`, under the
  app's; both stack). Update runs `CLIUpdateCommand.forCLI(installed:)` and
  only when `canUpdateCLIInApp`; any other CLI gets the `CLIUpdateAdvice`
  command in a `DMCommandBlock`. On 0.7.31+ the done card reads "CLI updated
  to X · packages pinned vN · skills updated" (the version from `devmachine
  version`, the rest from the report), and a pin it reached clears the
  packages card. Later is saved per CLI version
  (`UpdatePreferences.cliLaterVersion`) and hides that version and older
  ones (`CLIUpdateToast.shows`); a running or finished update shows
  whatever Later said, the finished one until Close. Details opens
  Settings → About. Demo shots `65`–`69` and `57` (a 0.7.31 CLI) in the
  `cli-update` walk.
- **A newer packages release gets its own corner card**
  (`PackagesUpdateBanner`, under the CLI's; all three stack). On CLI 0.7.31+
  `check` also runs `packages outdated --format json` (the CLI caches it a
  day and falls back to its last answer offline). It fails only when it never
  had an answer: that is "unknown", so no card and only a log line
  (`Logger` category `updates`), never an error on screen. `pinned` "" with
  `newer` false means nothing is pinned: no card. Update runs `--skip-cli`;
  a report whose pin did not reach the release is a failure. Done says what
  moved and points at Settings → Machines ("Open Machines"); it never syncs.
  Later is saved per release (`UpdatePreferences.packagesLaterVersion`) and
  hides it and older ones (`PackagesUpdateToast`, compared by
  `PackagesVersion`); Details opens `notes_url`. Demo shots `53`–`56`.
- Pure logic lives in `DevmachineCore/Updates` (versions, release JSON, ETag
  feed, schedule, install method, digest, bundle checks, swap, the update
  commands, their JSON and the packages card rules); the app's
  `Updates/` folder holds `UpdateController` and the real system calls. Tests
  inject fakes; nothing in `swift test` reaches the network, except the
  opt-in `DEVMACHINE_UPDATE_E2E=1` test, which installs into a temp folder.
- Never test an install against `/Applications/Devmachine.app` or by running
  `brew upgrade`: both replace the owner's app. Use a temp folder.
- A disk image install trusts only a bundle signed by the running app's Team
  ID. A local ad-hoc build has none, so it links to the release page instead.
- `scripts/package_app.sh` takes the version from the newest `v*` tag when
  `DEVMACHINE_APP_VERSION` is unset, so a local build compares correctly.
- AppKit will not quit while any window has a sheet attached (the log says
  "App termination blocked by modal sheet"), and the update dialog is a
  sheet. `AppRelauncher` starts the helper first (`DetachedProcess`: its own
  session, none of the app's open files), ends every sheet, then terminates.
  The helper opens the app only once the old pid is gone, never a second copy
  beside a stuck one; if the app is still running 10 s later, the dialog, the
  toast and About ask to "Quit and Reopen".
- To watch a real relaunch, run a debug build from a temp `.app` with its own
  bundle id: `open --env DEVMACHINE_DEMO=1 --env
  DEVMACHINE_RELAUNCH_REHEARSAL=<another .app> <copy>.app`. It "updates" to
  the other bundle through the real dialog, swap and relaunch. Debug only.

## Publishing through another machine
- **A workspace on a machine without Caddy is published by one that has
  it** (`expose add --via`). The add sheet's "Published by" lists the
  non-self machines with caddy (`CaddyStore.publishPlaces`); the
  workspace's own machine wins when it has caddy, then the machine the
  Published apps page shows, then the first. `via` is passed only when it
  differs from the workspace's machine, so nothing changes for a machine
  that serves its own sites. Nothing known about where things live means
  no `--via`, as before.
- The Published apps page of a machine with caddy also offers the workspaces
  of machines without it. After a publish, the serving machine is the one
  read again, not the workspace's.
- An older CLI answers `unknown flag: --via`; the card says to run
  `devmachine update` instead of showing Cobra's usage text. A published
  site whose serving machine cannot reach the port is live with an
  attention step carrying the CLI's note.

## DNS provider setup
- **A server with caddy and no DNS provider that answers gets a card on
  the Published apps page** (`DNSProviderSetupCard`, `DNSSetupStore`, state in
  Core `DNSProviderSetup.evaluate`). Without one, `expose add` saves the
  site and only prints the record to make by hand; the card says so.
  Only `dns providers` answering with a zone ends it: a finished sync that
  still sees none keeps the card on "Run sync". A machine that could not
  be asked shows no card (fails open).
- Declared providers come from `packages list` (`installed_on`). A CLI
  that reports `kind`/`credentials` (0.7.27+) is read by `kind == "dns"`
  alone; an older one by the summary "DNS zones on …". The token is stored
  under the package's declared secret credential, else the package name.
- Add = `packages add <p> --machine <m> --yes`, then the zones if typed,
  then `secrets set <secret> --stdin`: all local to this Mac, behind one
  confirm. The token goes on stdin only, never argv, logs or the job
  output. Run sync = `sync --machine <m> --tags <p> --yes` then
  `credentials push --machine <m> --yes`, behind a confirm, as a machine
  job in the corner (`MachineJobCenter`), which holds the log; the card
  only says where it stands. A failed job retried or dismissed in the
  corner moves the card with it. A CLI older than 0.7.24 gets the commands.
- Hostinger's `hostinger.zones` is set with `machines edit <m> --set
  hostinger.zones=[…] --yes` behind a confirm on CLI 0.7.27+, after the
  package is added (the CLI refuses a setting for a package not there).
  Zones are plain names only (`DNSProviderCatalog.zones`). An older CLI
  gets a `config.yml` snippet; the app never edits `config.yml`. Demo
  mode refuses every write.
- `DEVMACHINE_DEMO_WALK=dns-setup` captures every state; its sync runs on
  a demo center whose runner is `DemoDNSSyncRunner`, which starts no
  process. Outside the walk, demo mode's sync fails in the corner.

## Machines and the Add machine wizard
- **Settings → Machines lists the CLI's configuration** (`MachinesStore`:
  `config path`, `version`, then `machines list` and `packages list`). A
  machine's packages are its own `packages` from `machines list` (CLI
  0.7.27+), else the `installed_on` of `packages list`. Before `config.yml`
  exists an older CLI fails every one of those calls, so the store checks
  the file first and reads "no machine" without calling them; a CLI with
  `MachineUnattendedAdd` lists the latest release's packages then, for the
  first machine (a failure there is no error: essentials is still offered).
  Remove runs `machines rm --yes` behind a confirm and only forgets the
  machine. A load asked for while one runs reads once more after it, so
  the last change on disk is always the one shown.
- **The sidebar offers "Add a machine" above Local only once a read says
  there is none besides this Mac** (`AddMachinePrompt`). Nothing is gated
  on a machine: Home and local sessions work with zero. One rule in
  `AppSettings.validate` covers both this and onboarding: Public IP and Base
  domain are optional (checked only once typed, filled from the CLI when it
  knows them); the CLI's own folder passes before `devmachine setup` writes
  its `config.yml`; only a missing CLI or another folder without
  `config.yml` blocks Save, with the setup flow as its fix. That folder is
  never silent: `AppSettings.notices` gives a non-blocking "No machine
  yet" with Run setup (onboarding) and Add a machine (the wizard); a fresh
  Mac that landed on Settings had nowhere to go. Demo shot:
  `95-settings-no-machine.png` in the setup-flow walk.
- **The wizard (`AppPage.addMachine`) only builds `devmachine` commands**
  (`MachinePlan`, Core) and shows them before Create. Packages are
  `--no-essentials` or `packages add`, then `workspaces new <w> --machine
  <m> --yes` (optional here, required by default on the first run) and
  `sync`. A workspace name is its Linux account's: the CLI's
  `linuxUserName` rule, at most 32 characters, not a system account or
  the admin login, not a workspace the configuration has
  (`WorkspaceName.problem`, shared with Settings → Workspaces). Package cards are machine packages whose `platforms` hold `linux`
  or are empty (any): a server and a Lima machine are both Linux, so a
  `[macos]` package is never offered. Essentials is always installed
  (locked, its `needs` listed as included and not offered again on their
  own); docker is suggested and checked (`MachinePackageCatalog.suggested`).
- **The column beside the form is never empty.** Before the run it holds
  `AddMachineSummaryView`: the answers so far (`MachineWizard.summary`,
  read from the same plan that runs) and the commands they would run
  (`previewCommands`, none until the machine has a name; on the review
  the commands are the page, so only the summary). The kind step has
  nothing to summarise, so its two cards take that room. The run puts its
  log and steps in the same 340-point column (`AddMachineContent.sideWidth`).
- **CLI 0.7.27+ adds with no terminal at all**
  (`MachineUnattendedAdd.minimumCLIVersion`, read from `version` into the
  `MachinesSnapshot`). Every answer is a flag: `machines add --address
  --fingerprint` with `--key <file>`, `--key agent:SHA256:…` (keys listed
  with `ssh-add -l` against the socket the app hands the CLI) or
  `--password-stdin`; `--domain` only for the first machine, which `add`
  then writes the configuration for, as `setup` would; a Lima machine is
  one `create-local <name> --add`. The steps run in the background
  (`MachineStepRunner`, `runProcess`), output shown as it comes; `add` writes
  the machine only once its key is proved, so Try again simply runs the
  failed step again.
- **A Lima machine is sized from this Mac on CLI 0.7.28+**
  (`LocalMachineSizing`, `LocalMachineSizeLimits`): CPUs up to every core,
  memory up to the Mac's minus 2 GiB, disk up to the free space minus
  10 GiB (Lima's disk grows as it fills). The default is half the cores
  (2–4), a quarter of the memory (4–8 GiB) and 40 GiB, clamped. The size
  goes to `create-local --add --cpus --memory --disk` and the review
  says it; an older CLI shows no controls, gets no flags, and a note
  names its own default size. Demo and tests inject the limits
  (`DemoData.macLimits`), never this Mac's.
- **The password is a `SecretText`**: in a `SecureField`, on the add's
  stdin and nowhere else. The step carries only `input: .password`, never
  the value, so it is in no argument, step id, display line or log;
  printing the draft shows dots. It is written to the pipe before the
  process starts (no SIGPIPE if the CLI exits first). The draft drops it
  when a run starts, whatever the outcome, when the page goes away, and
  when the context is read again; a Try again that needs it opens the
  answers instead.
- **The fingerprint is read before anything trusts it** (`machines scan
  --format json`, logs in nowhere, writes nothing): the wizard shows the
  presented key beside the CLI's `verify` command for the provider's
  console. `--fingerprint` is the console output pasted, or the scan once
  the person ticks that the console shows the same key; a paste that
  disagrees with the scan trusts nothing. A scan of another address or
  port counts for nothing.
- **An older CLI keeps the terminal flow.** A server whose key already
  logs in is added unattended; a password-only server, a Lima machine
  (`create-local`, then `machines add`) and the very first machine (`setup`)
  go through the CLI's own questions, and the page lists the answers to
  type. The commands run in a local terminal pane (`MachineStepRunner`), so
  a password goes straight to the CLI. Only `sh <script>` is typed (any
  login shell, fish included); the script prints a per-step nonce marker
  the runner finds in the scrollback. A failed step shows
  `DMErrorStateView`; Try again skips the steps done. Tests inject
  `MachineStepRunner.Hooks`; nothing types into a real pane or starts a CLI.
- **No run waits forever.** Stop ends a run in either mode (Ctrl-C into
  the pane, or the background process is cancelled, which
  `StreamingProcess` turns into SIGTERM). A terminal step that ends
  without its marker is noticed when the pane's shell is its terminal's
  foreground group again, twice in a row (`ProcessTree.isAtPrompt`), and
  any step fails after `stepTimeout` (3 h: a first sync is slow) with
  what to do.
- **A failed run goes back to its answers.** "Edit answers" (and Close)
  return to the details with every answer but the password; steps done
  stay done, and the machine the run already wrote does not block its own
  name. Reopening after a success starts fresh. When the context is read
  again (a newer CLI found meanwhile), the wizard returns only as far as
  every step before is still valid (`MachineWizard.restore`), so a step
  that now needs a password or a fingerprint is where it stops.
- **No `config.yml` means no machine, not an unread list**: `machines
  list` fails before it exists, and `StatsStore` then checks the file and
  drops its cached cards, so Home never shows machines from an old
  configuration. Any other failed read keeps the cache.
- `DEVMACHINE_DEMO_ONLY=id,id` captures only those screens of a walk.
- `DEVMACHINE_DEMO_WALK=machines` captures Settings → Machines, every
  wizard step (key file, password, agent key, scan), a background run in
  each state, the first machine with its domain, the sidebar with no
  machine (Home with no machine cards), `legacy-` shots of an older
  CLI's terminal flow, and `cli-socket-` shots (Home and Stats on a CLI
  whose socket path is too long). Demo mode scans no server and reads no agent
  (`DemoData.addMachineScan`, `addMachineAgentKeys`) and refuses every run:
  `MachineStepRunner.run`, `MachinesStore.removeMachine`,
  `PackagesStore.apply` and `ProcessJobRunner` (every machine job: Prepare,
  DNS sync, Packages sync) each refuse before reaching a terminal or the CLI
  (`DemoRefusalTests`).

## Machine location and the network map
- **A machine's location is the CLI's** (`machines[].location`, CLI
  0.7.30+, `MachineLocation` in Core): trimmed, lower-cased,
  `[a-z0-9][a-z0-9 ._-]{0,39}`. A CLI that leaves the field out reads as
  `local` for this Mac and a Lima machine (only host `127.0.0.1`), else
  `external`; an empty value is `external`. The wizard always asks
  (`MachineLocationField`: free text plus chips; default `external` for a
  server, `local` for Lima) and passes `--location` to `machines add` /
  `create-local --add` only on 0.7.30+; older, it says the location is kept
  once the CLI is updated. "Edit location" runs `machines edit <m>
  --location <v> --yes` on Save (config only); an older CLI gets "Update the
  CLI" instead.
- **Settings → Machines opens on a network map** (`NetworkMap`,
  `NetworkMapGeometry` in Core; `NetworkMapView` draws it in a `Canvas`
  after the website hero's hairline plates, creases and coins). One row of
  tiles, zones by location (this Mac's first, then zones with a door, then
  by name), columns fixed by sorting, so the same configuration always
  draws the same map; the scale fits the width (0.9–3 pt per unit).
  Links are only what the configuration proves: internet → every non-self,
  non-Lima machine with caddy/essentials (`https`); each site from Caddy's
  listing (`CaddyStore.sitesByMachine`) from its door to the machine whose
  `workspaces` holds it (`expose --via` shows as a lane to another
  machine); this Mac → every machine (`ssh`, drawn even without a self
  machine, then not selectable); a dashed chain between machines with a
  tailnet host (`100.64.0.0/10` or `tailscale:`). This Mac is never put on
  the tailnet: nothing says it is. Lines rise straight up from a tile and
  run along a lane above the row, so nothing crosses on the ground; at most
  6 sites are drawn, the rest counted. A click on a tile selects its card.
- **The map is one view with two presentations** (`NetworkMapView`,
  `NetworkMapPresentation` in Core). `.interactive` is the page above.
  `.decorative` is Home's wallpaper in two sizes (`WallpaperChoice.networkMap(
  NetworkMapSize)`, saved as `{"kind":"networkMap","size":"large"|"compact"}`;
  a value saved before there were two sizes, or a size a newer build wrote,
  reads as compact; a build older than the map reads it as the bundled
  photo): no hit testing, no selection or hover, ink at 45%, no site hosts
  (they ran under the clock's digits) and no "+N more", and its site lanes
  sit closer (`NetworkMapBackdrop.siteRow`). The grid covers all of Home.
  - **Compact** goes only in Home's free area (`HomeMapArea.rect`, Core):
    right of the cards column and under the clock and date when they sit
    side by side, under everything when Home is stacked, always above the
    stats pill. HomeView measures the clock, the stacked content and the pill
    in its `home` coordinate space and the plan gives the cards column.
    The map is centred on the clock's middle, not the free column's
    (`NetworkMapBackdrop.compact`): the area is narrowed the same on both
    sides of the clock's x (`HomeMapArea.centred`), so it still keeps clear of
    the cards; only when that leaves the map below scale 0.5 does it centre
    in the free column. The clock centres in all of Home when it can, and a
    map centred in the column then sat off to its right. Inside its area
    `NetworkMapBackdrop` keeps 12% margins (16 pt at least there), at most
    scale 2, shrunk whole to fit; no area, or a map that would draw below
    scale 0.5, leaves the grid alone.
  - **Large** sits behind everything, cards and clock drawn over it
    (`HomeMapArea.large`, `NetworkMapPlacement.filling`,
    `NetworkMapBackdrop.Fit.large`): a rect centred in all of Home, 70% of its
    width, with the same room top and bottom so it clears the pill by the gap
    and stays centred. It is spread around the clock's measured frame (time,
    date and Mac name) so that band stays empty
    (`NetworkMapGeometry.spread`, `keepClear`): the internet tile at the top,
    the machines in a row at the bottom, placed on the two sides of the band
    with a wider pitch, and the lanes above the band (or between it and the
    machines, with the internet tile moved beside the band). The search goes
    from scale 3.5 down and takes the first layout that keeps machines off
    the band and no line through it; only when none fits may a thin vertical
    cross it; with no room at all it falls back to the map centred in the
    rect. Owner feedback: the clock sat on the map's middle, digits over the
    internet tile and the server. The Machines page never spreads (its
    snapshots are byte-identical to before).
- **Settings → Appearance opens on a Background picker** (`WallpaperKind`,
  Core): four `DMPictureChoice` cards, Photo, Gradient, Network map — large,
  Network map — compact, the chosen one ringed and checked. The map cards draw
  a miniature Home (`HomeSketch`: a 760-point-tall Home scaled down, so the
  map lands where Home puts it, spread around the sketch's clock, and is not
  dropped as too small). Picking Photo or
  Gradient comes back to the last photo or gradient picked (else the bundled
  photo, `midnight`), then shows that kind's own picks under the cards: the
  theme chips and photos, or the gradients. Every picture there is 150 pt tall
  and cropped, in a grid that wraps (200–300 pt columns), so it never turns
  into a strip; thumbnails are fetched at 640 px (`-thumb640.jpg`, so an old
  320 px file is not reused).
- **The wallpaper reads no data of its own** (`NetworkMapWallpaper`): on
  appear it loads `MachinesStore` only if nobody has, and asks
  `CaddyStore.appearForMap` for the sites (cache first, read again only past
  their TTL, never DNS). Before any data, and with no machine, only the
  ground shows; the machines fade in (no fade with Reduce Motion). Both
  canvases are `Equatable`, so a stats tick or usage refresh on Home does
  not repaint them, and there is no motion to keep them busy. Only the
  bottom is dimmed (`WallpaperBackground.dimming`); behind terminals the
  ambient backdrop is the ground without the grid. The Appearance cards draw
  the same view inside their miniature Home.
- `DEVMACHINE_DEMO_WALK=map-wallpaper` (`DemoMapWallpaper`) captures
  `180`–`190`: Home with the compact map over the demo configuration, over
  the five-machine fleet, with no machine; Appearance on the large map; Home
  with the large map over both; Appearance on a photo theme and on the
  gradients; and Home with the sidebar collapsed, with the compact map and
  with the large one over both configurations. Run it with
  `DEVMACHINE_DEMO_WINDOW=1280x800` and `1728x1080` to check laptop sizes.
- **Per machine**: Check (`doctor --machine`, `machine doctor` for this
  Mac), Addresses (`resolve`), Credentials (`credentials list`) open inline
  and are read only when opened (two of them log in); Sync asks
  `PackagesStore.syncPending` (disabled with nothing waiting), Full sync a
  full `SyncRequest`; a Lima machine gets Start / Stop and Delete the VM
  (`delete-local --yes` behind a confirm that it destroys the VM, apart
  from Remove which only forgets). All runs are machine jobs; their PATH
  has `~/.local/bin` first for an app-installed Lima. "Packages on this
  machine" opens Settings → Packages through `AppModel.openPackages`.
- `DEVMACHINE_DEMO_WALK=machines-map` (`DemoMachinesMap`) captures
  `160`–`172`: the fleet, a selection, each panel, a Lima start in the
  corner, one and eight machines, the location editor, the wizard's
  field on a current and an older CLI, the SSH password login panel, and
  the wizard keeping one account's password.
  Nothing runs.

## SSH password login
- SSH has one password setting for the whole machine, so turning it off
  reaches every account: on a Mac, the people who use it too. The wizard
  asks (`PasswordLoginChoice`): off for every account (no flag), off except
  some (`--keep-password-login`, CLI 0.8.2+, hidden on an older one), or
  left as it is (`--no-harden`).
- The machine's "SSH password login" panel reads `machines password-login
  --format json` and changes it with `--keep`/`--off`/`--on --yes`, then
  reads the machine again: what it shows is sshd's answer. "On for every
  account" is disabled while the machine has `ssh_hardening`, which turns
  it off again on every sync.

## Machine jobs
- **Every `devmachine` run against a machine is a machine job** (`MachineJobCenter`,
  `MachineJobToast` in the corner stack): Prepare, the DNS provider sync and the
  Packages page's sync. A screen never streams a sync into its own layout.
- **A sync is asked for, not started** (`requestSync`): the card asks "Sync
  <machine>?" and runs only on its button, which is the confirm the VPS-writes
  rule needs. Two asks for one machine merge into one card (tags join, full
  wins). One job runs per machine; the next waits as queued.
- **A tagged sync never records a removal** (the CLI's lock only updates tagged
  entries), so a request with a removal, or a CLI before 0.7.24, starts full.
- The log keeps the newest 5000 lines (`JobLog`) and arrives in batches
  (`JobOutputBuffer`): a hop per line carrying the whole log froze the window.
- `DMLogView` anchors its scroll at the bottom: `scrollTo` alone, on a lazy
  stack of wrapped lines, stopped a line or two short of the error.

## Packages page
- Settings → Packages reads `packages list`, `config show` and `packages.lock`.
  Declared is `installed_on`; applied is the lock (machines and workspaces).
  A package the lock has because another one `needs` it is "via <parent>",
  never "pending removal"; a workspace always has `workspace` (the CLI adds it).
- "Pending" is derived from config and lock, so a sync put off with Later is
  still offered ("Sync now") after a relaunch.
- Apply runs `packages add|rm … --yes` one by one; the first failure stops it and
  asks for no sync. Removing never uninstalls: the row and the confirm say so.
- `DEVMACHINE_DEMO_WALK=packages` (`DemoPackages`) seeds the store and the
  corner at each moment (every machine, `main` with two ticks, the confirm,
  the sync pending, running, done, failed); nothing runs.

## Scheduled page
- Schedule is a mode (⌘3, the sidebar title, the menu bar footer's clock and
  ⌘K "Schedule"): `showPage(.scheduled)` switches to it. The sidebar lists the
  tasks by workspace (`ScheduleSidebar`) with "New task" on top, which asks
  the page for its sheet (`ScheduledStore.requestNewTask`); the page
  (`ScheduledView`) is unchanged beside it. It reads `scheduled list` (every
  workspace at once; one that is not set up is `installed: false` and is not
  asked) and `scheduled harnesses`.
- The agent, permission-mode and model pickers come from `scheduled
  harnesses`, never from a list in the app: a new agent in the CLI needs no
  app release. A mode in `dangerous` needs the sheet's "I understand" and goes
  as `--allow-dangerous`.
- Create on a workspace without the package asks first ("Set up and
  create"), then runs `scheduled add --yes`, which adds the package and syncs
  the machine before saving; it can take a minute or two. That setup is a
  global job card (`beginTask`, no count) while the Create button spins.
- A failed setup: the CLI prints the whole Ansible run on stderr before its
  `error:` line, so every scheduled call reports `CLIStderr.reason` (the last
  `error:` line). Showing the start of stderr once made a failed setup look
  like no error at all. The sheet keeps the form, shows the error with Try
  again, and the list is read again.
- A workspace whose list error is `setup-incomplete` (package in config, no
  binary) gets "Finish setup" on its banner: `sync --machine <m> --tags
  scheduled --yes`, shown with the same job card (`finishing: true`). A failed
  finish stays on the banner (`setupErrors`). Demo walk `scheduled`, screens
  143-146.
- Edit sends every field (`ScheduledDraft.arguments`), so an empty model
  clears it. Run now starts the run and polls `scheduled runs` every 2 s until
  it ends (10 min at most). A `missed`/`skipped` run has no output; its
  message is shown instead.
- Go writes times with nine fraction digits; `ScheduledJSON.parseDate` cuts
  them to milliseconds before Foundation reads them.

## Settings → Workspaces
- **Settings → Workspaces lists every workspace under its machine**
  (`WorkspacesSettingsView`, `WorkspacesStore`: `workspaces list --format
  json` with its `settings`, and `packages.lock`; grouping in
  `WorkspaceSettingsList`, Core). Each machine has a title with its
  location; machines in the configuration's order. A sidebar workspace the
  CLI's list does not hold goes under "Other workspaces", so its switch is
  never lost. "Applied", "Waiting for sync" or "Not created yet" come from
  the lock's `workspaces` map (`WorkspaceSync`): every declared package in
  it is applied. A package taken off is not caught: the lock also lists
  what the declared ones pull in. No `config.yml` yet means no workspace,
  without a list call. There is no separate page (`AppPage` has no
  workspaces case) and no "Manage workspaces…" button: the list is the
  section, at the full width and height.
- **Each row's switch is the sidebar's on/off** (`AppSettings.hiddenWorkspaces`
  by ssh alias, `WorkspaceVisibility.setting`). It saves at once, with no
  Save (`AppModel.setHiddenWorkspaces` writes only the hidden list), and a
  workspace off is not reached: no ssh, mosh or poll, its panes closed.
  The section has no Save footer, like Packages.
- **Reached from** the sidebar's + beside WORKSPACES ("New workspace…", under
  the new-session items), ⌘K "Workspaces…" (`openSettings(.workspaces)`) and
  "New workspace…" (`requestNewWorkspace`: Settings → Workspaces plus
  `pendingNewWorkspace`, taken by the view).
- **A flow opens inside the section, under a breadcrumb** ("Workspaces ›
  Edit acme", "Workspaces › New workspace"), with the Settings rail beside
  it and its buttons at the bottom. "Workspaces" goes back to the list,
  except while a run is going (Stop first). Leaving the section or closing
  Settings drops any flow that is not running (`WorkspacesStore.leave`, from
  the view's `onDisappear`): the store lives for the app, and a flow kept
  there once left Settings stuck on the last workspace clicked. There is no
  side column: New and Edit show their commands on the review step, Forget
  and Destroy on their own screen.
- **Edit never changes packages**: they live in Settings → Packages.
  `WorkspaceFlow.togglePackage` does nothing for Edit, so its plan has no
  `--add`/`--rm`. Edit shows the packages as labels and "Packages for this
  workspace →" (`AppModel.openPackages(workspace:)`, which opens Packages
  with its Workspace dropdown set, `PackagesPageState.requested`), then
  the declared variables, other settings and logins. New keeps its package
  picker: a workspace has to start from some list (`defaults.workspace`
  and the harnesses turned on). Onboarding and Add machine make the first
  workspace through `MachinePlan` (`workspaces new … --yes`) and never use
  this section.
- **Every flow is a `WorkspaceFlow` (Core) and runs through
  `MachineStepRunner` in the background**, with `MachineRunLayout`,
  `DMLogView` and `SetupFailurePanel` (Retry, Report a bug), like the wizard.
  New and Edit: form, review of the exact commands, a confirm, run. New is
  `workspaces new <w> --machine <m> --packages a,b --yes` (`--packages=` when
  every card is off) then `sync --machine <m> --yes`; Edit is `workspaces edit
  <w> --add/--rm/--set/--unset … --yes` then the same sync, never `--machine`
  (there it moves the workspace). "Apply it now" off skips the sync.
- The name uses the wizard's rule (`WorkspaceName`); the machine picker lists
  non-self machines only. New's package cards are workspace packages for
  Linux, grouped by `category`, the account package `workspace` locked on.
- **CLI 0.7.29 reports what the page used to guess** (`WorkspaceJSON`, read
  from `version`; an older CLI keeps the fallbacks). `config show` gives
  `defaults.workspace`, which is the preselection and the DEFAULT badge
  (fallback: the setup's own `dev`, `zsh`, `mise`, and the form says it
  cannot read yours), and the top-level login answers. `packages list` gives
  each package's `variables`: Edit shows one typed field per declared
  variable of the workspace's packages (boolean as Default/On/Off, list and map as
  YAML text, a number checked before Continue), empty meaning the default;
  anything else stays in the free-text "Other settings". `workspaces list`
  gives each workspace's own `credentials`: Edit lists the logins its
  packages declare (`WorkspaceLogin`: the workspace's answer, then the
  configuration's, then the package's scope) with As configured / Shared /
  Own, written as `--share <login>=machine|own`, or `<login>=` to follow
  the configuration again. A login whose `credentials[].shareable` is
  false (CLI 0.7.29 with `shareable`; always false for a secret or a file)
  offers only As configured / Own, with the reason, and follows `own`
  whatever the configuration says, as `sync` does. A CLI that leaves
  `shareable` out keeps all three, and a Shared it refuses fails at the
  sync with its message.
- Edit mirrors the CLI's checks: a free-text setting is `<package>.<name>`
  for a package the workspace keeps, with a value (an empty `--set` would
  remove it). The machine and the account stay in the terminal.
- **Forget and Destroy are different on purpose.** Forget is `workspaces rm
  <w> --yes` behind a confirm: only this Mac's configuration changes. Destroy
  is `workspaces destroy <w> --confirm <w>` (+ `--keep-dns`, a checkbox) and
  runs only once the name is typed exactly. The CLI's refusals (a site
  published through another machine, an unreachable machine) are its
  `error:` line, shown as the failure's cause; nothing is guessed.
- Once a step changed the configuration, "Change answers" is gone (the name
  now exists); Retry runs only what failed. Any run that changed something
  reloads the sidebar, Settings → Machines, readiness and the cached
  workspace list.
- Demo mode reads `DemoData.workspacesSnapshot` and refuses every run ("Demo
  mode never changes a workspace."). `DEVMACHINE_DEMO_WALK=workspaces`
  captures `130`–`144`, all inside Settings: the list by machine (umbrella
  switched off), new, a taken name, review, running, failed, done, edit,
  edit review, forget, a refused forget, destroy, the list again after an
  edit was left (`142-workspaces-reopened`), a new workspace with no
  harness on, and Settings → Coding agents (every harness with a package has a
  switch). It turns on Claude, Codex and Pi, and Edit shows glab's login,
  which cannot be shared.

## VPS writes
Features that write to the VPS or public DNS run only on an explicit user action
in the app, behind a confirm, and never from tests. The app delegates publishing
to `devmachine expose`; it does not edit Caddy, DNS, or Ansible itself.
