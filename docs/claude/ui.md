# UI rules and the component library

Part of the devmachine-app guidelines. `CLAUDE.md` is the index and
holds the rules that apply everywhere; this file is binding for its area.

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
- Sidebar / menu bar entries for pages (Stats, Publish, …) SET `activePage`;
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
- The window server drags the window from any part of the band that no view
  claims, before the app sees the click, so a terminal line under the band
  moved the window instead of selecting. `SelectingTerminalView` claims its
  bounds through AppKit's private `_opaqueRectForWindowMoveWhenInTitlebar`
  (NSButton does the same; there is no public API). Moving the terminal
  below the band instead left an empty strip and was rejected.
- A SwiftUI control under the band never gets its tap, so the tab strip's
  chips did nothing. Two things take the click first: the window server
  (any spot no AppKit view claims drags the window) and, inside the app, the
  toolbar's `NSToolbarView`, which sits over the content and is what a click
  in the band hits. It passes a click on only to the claimed spots it knew
  when it last measured them, so a tab opened later stayed dead until the
  terminal was touched. A control under the band takes `.titlebarClick`
  (`TitlebarClickTarget`): an NSView over it that claims its bounds, gets the
  press from `TitlebarClickRouter` (a local event monitor) and runs the
  action itself on release, with a right-click menu. Forwarding the press to
  SwiftUI's hosting view was tried and the tap never fired. Claim the
  controls, not the whole strip, so its empty part still drags.
- **Full screen hides the toolbar** (`WindowButtonsReader`, on will-enter;
  shown again on will-exit). A visible toolbar stays on screen there as an
  opaque grey band that pushes every column down. The window buttons then live
  in the title bar's own window, so their converted place means nothing: the
  reader keeps the windowed place (`SidebarHeaderSpacing.fallbackButtons` when
  the window opened in full screen), or the sidebar header, its list and the
  context tabs drop to the middle of the screen.
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
