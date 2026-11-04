# Terminals

Part of the devmachine-app guidelines. `CLAUDE.md` is the index and
holds the rules that apply everywhere; this file is binding for its area.

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
- **Nothing on screen holds the whole file** (`FileChunks`, `FileLayout`,
  cut off the main thread with the read). SwiftUI lays out everything in a
  plain stack before the first frame: one `Markdown` view of a 130 KB file
  took 2.3 s, one `Text` of it 4.6 s, and worse than linear, so a 200 KB
  markdown froze the app. Lines go in pieces of 200 into a `LazyVStack`,
  each piece one `Text` with its numbers in one `Text` beside it, and the
  width is the longest line's from the start so the horizontal extent does
  not jump; markdown is cut at blank lines outside fenced code into pieces
  of about 4 KB (reference link definitions repeated in each), and each
  piece is its own `Markdown` view. 130 KB now lays out in ~100 ms, 1 MB
  the same. Highlighting asks highlight.js once per file, off the main
  thread, and slices the result into the same pieces
  (`AttributedLines.split`); it drops blank lines at the end of a file,
  which are put back, and any other mismatch leaves the plain text. The
  viewer does not observe `AppModel`: it has nothing to read there, and
  every poll would have re-evaluated the file.
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

## Tab strip over the terminal
- **The strip shows the workspace on screen** (`AppModel.visibleTabs`,
  drawn by `CenterTabStrip`): the session and file tabs whose owner is in the
  selected session's workspace (Local is a workspace). Home, a page and the
  session grid show none; the other workspaces' tabs stay open in
  `openTabs` and come back with a session of theirs. Closing the session
  tab on screen moves to its neighbour in the same workspace
  (`TabList.close(_:selected:among:)`), or Home when it was the workspace's
  last, never to another workspace.
- **⌘W closes a tab and ends nothing.** `handleCloseCommand` closes a
  preview with the keyboard first, else `tabOnScreen` (the file the viewer
  shows when it has a tab, else the session's tab); the session keeps
  running, as the chip's × does. With no tab on screen ⌘W closes the
  window. **⇧⌘W is "End Session…"** (`requestEndSession`, the sheet), the
  same action as the sidebar's row menu and ⌘K. The owner asked for this
  split: ⌘W opening the End session sheet while × only hid the tab read as
  two different closes.
- **A file tab shows its file in the terminal's place**, the way a session
  tab shows its terminal (`MainPane`): the viewer takes the terminal's card
  and the terminal is unmounted, never resized, so the program inside comes
  back as it was; selecting the session tab closes the viewer and asks the
  pane to draw again (`AppModel.fileClosed`, the same repaint as after a
  page). The owner asked for this: a file beside the terminal, in a pane
  with a strip of its own, was a second set of tabs to read. The pane
  beside the terminal (`DocumentPane`) holds preview tabs only. Closing the
  file tab on screen moves to its neighbour in the workspace, as closing a
  session tab does. The viewer keeps what the last few tabs read
  (`FileViewerStore.cached`, `cacheCap`), so coming back to a tab is as
  quick as coming back to a session; Reload reads again, and a closed tab
  is forgotten. Without the strip (Settings → Appearance) the viewer's own
  header carries the tab and the × that puts the terminal back.
- Demo walk `DEVMACHINE_DEMO_WALK=tabs`: `36`–`39`: a globex session with
  acme's tabs hidden, then a file tab on screen.
