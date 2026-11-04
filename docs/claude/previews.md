# Previews and the in-app browser

Part of the devmachine-app guidelines. `CLAUDE.md` is the index and
holds the rules that apply everywhere; this file is binding for its area.

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
  `DocumentSplit` in Core). The pane holds preview tabs only; an open file
  is a tab over the terminal and shows in its place (see Tab strip over the
  terminal in `terminals.md`). The pane's share is a fraction, saved only when a
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
