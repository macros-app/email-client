# macros-email-client

A mu4e-style **Gmail client** for the [macros](https://codeberg.org/macros-app/macros)
editor, written entirely in Steel, with **multiple mailboxes** and
**pluggable authentication** per mailbox: OAuth (Gmail REST API) or an app
password (real IMAP/SMTP). Login, sync, local storage/search, sending, and
the UI are all one package running inside the editor.

```
M-x email        (or  C-c m)
```

Press `L` to log in the first time, then `G` to sync. With several accounts
configured, `a` cycles between them and `M-x email-switch-account` prompts
by name.

## Configuring a Gmail account

The **`email-accounts`** option is an **array of account configurations** — a
JSON array of objects, one self-contained config per mailbox. Every field
except `name` is optional and falls back to the matching global `email-…`
option, then a default:

```scheme
(package-install "https://codeberg.org/macros-app/email-client"
  'config (lambda ()
            (set-option "email-accounts"
              (string-append
               "["
               "  {\"name\": \"me@gmail.com\", \"method\": \"oauth\","
               "   \"client-id\": \"…apps.googleusercontent.com\","
               "   \"client-secret\": \"…\"},"
               "  {\"name\": \"work@corp.com\", \"method\": \"app-password\","
               "   \"query\": \"in:inbox OR label:team\"}"
               "]"))
            ;; Shared defaults — any account object may override these:
            (set-option "email-query"         "in:inbox") ; REST sync scope
            (set-option "email-name"          "Your Name"); From: display name
            (set-option "email-data-dir"      "~/.macros-email")
            (set-option "email-mode"          "live")     ; or "offline" (see below)
            (set-option "email-auto-sync-minutes" "5")))  ; unset = manual G only
```

Recognized per-account fields (all optional except `name`): `method`,
`client-id`, `client-secret`, `query`, `address` (From: address),
`from-name` (From: display name), `imap-host`, `smtp-host`, `mode`,
`maildir`, `fetch-count`, `auto-sync-minutes`. Put shared values in the
global `email-…` options and only the per-mailbox differences in each object.

The first entry is the default active account; `a` cycles and
`M-x email-switch-account` prompts by name. A simple setup can still use the
legacy string form — `"me@gmail.com|oauth work@corp.com|app-password"`. If
`email-accounts` is unset you get a single account named `default` whose
method comes from the `email-auth-method` option (default `"oauth"`).

A few more optional overrides (rarely needed): `email-address` sets the
`From:` address when it differs from the logged-in account (send-as aliases);
`email-git-repo` sets the default repo for the patch workflow (below);
`email-maildir` turns on the automatic Maildir mirror (below); and
`email-imap-host` / `email-smtp-host` (default `imap.gmail.com` /
`smtp.gmail.com`) point the app-password backend at a different server —
though the sync relies on Gmail's IMAP extensions, so a non-Gmail host won't
fully work without code changes.

Then, **once per account**: `M-x email` → (switch to the account with `a` if
needed) → `L` to log in — the flow depends on the account's method — then `G`
to sync.

### Method comparison

| | `oauth` | `app-password` |
|---|---|---|
| Google-side setup | your own GCP OAuth client (~5 min, below) | 2-Step Verification + an app password (~2 min, below) |
| Credential stored | refresh token (keychain, per account) | app password (keychain, per account) |
| Transport | Gmail REST API (async) | IMAP 993 + SMTP 465 (blocking `tls-*`) |
| Sync | `history.list` incremental | UID/UIDVALIDITY incremental |
| Login UX | browser consent flow | two minibuffer prompts |

An account's **method can be changed later** by editing its entry: both
backends share the same on-disk store format (ids normalize on hex
`X-GM-MSGID`, which *is* the REST message id), so the index, message cache,
read/star state, and queued flag ops survive the change — you only log in
once with the new method's credential.

### Google setup for `oauth` accounts

1. Create a project at <https://console.cloud.google.com/>.
2. **APIs & Services → Library** → enable the **Gmail API**.
3. **OAuth consent screen** → External → add **yourself as a test user**.
4. **Credentials → Create credentials → OAuth client ID** → **Desktop app**;
   copy the client id + secret into the options above. One client can serve
   every oauth account — you pick which Google account to consent as in the
   browser each time you press `L`.

**Different GCP clients per account** just go in each account object's own
`client-id` / `client-secret` fields (above) — nothing global to set.

Gotchas of Google's making: while the consent screen is in **Testing**
status, refresh tokens expire after 7 days — push the app to **Production**
(it stays unverified; you click through the warning once) for long-lived
tokens. The "unverified app" interstitial on login is expected: *Advanced →
continue*. It's your own client; the only user is you.

### Google setup for `app-password` accounts

1. Turn on **2-Step Verification** at <https://myaccount.google.com/security>.
2. Create an app password at <https://myaccount.google.com/apppasswords>.
3. `L` in the account → enter the address, paste the 16-character password
   (spaces fine). It's verified against `imap.gmail.com` before being stored.

## Where mail is stored on disk

Everything lives under the **data directory** — `~/.macros-email` by
default, configurable with the `email-data-dir` option (a leading `~/` is
expanded). Each account gets its own subdirectory:

```
~/.macros-email/
├── personal/                  ← one directory per configured account
│   ├── index                  ← envelope db: one line per message (US-separated
│   │                            fields), sync baselines on the header line
│   ├── pending                ← queued flag ops awaiting the next sync
│   └── messages/
│       └── <id>               ← one normalized UTF-8 text file per opened
│                                message: decoded headers, body text, and an
│                                attachment manifest (bytes fetched lazily)
└── work/
    └── …
```

Message files are plain text on purpose — `grep-files`/ripgrep work over
your whole archive. Attachment *bytes* are not stored; they're fetched on
demand when you save one (`W`).

**Credentials are not in the data dir**: refresh tokens and app passwords
live in the macOS keychain, one entry per account
(`macros-email-refresh-token:<name>` / `macros-email-app-password:<name>`).
On systems without the `security` CLI they fall back to chmod-600 files
(`token` / `app-password`) inside the account directory.

## Keys

| *email* (list) | | *email-view* | | *email-compose* | |
|---|---|---|---|---|---|
| `?` | **menu (everything)** | `?` | **menu (everything)** | `C-c C-c` | send |
| `enter` | open | `enter`/click | follow link | `C-c C-k` | discard |
| `C` | compose | `n` / `p` | next / prev | `C-c C-a` | attach file |
| `R` / `E` | reply / reply all | `R` / `E` | reply / reply all | `C-c C-b` | add Bcc |
| `A` / `D` | archive / trash | `A` / `D` | archive / trash | `C-c C-l` | send later (outbox) |
| `U` / `*` | unread / star | `W` | save attachment | `C-c C-t` | menu |
| | | | | `M-i` | complete address |
| `s` / `/` | server / local search | `b` / `q` | Gmail web / back | | |
| `f` / `i` | folders / inbox | | | | |
| `a` / `O` | account / outbox | | | | |
| `g` / `G` | redraw / sync | | | | |
| `L` / `q` | login / quit | | | | |

`?` opens a magit-style transient listing **every command** (message actions,
flags, folders and search, account switching, Maildir export, index rebuild) —
nothing requires memorizing a key. Reply-all (`E`) addresses the original
sender and Cc's every other recipient of the message, minus you.

Evil/helix normal-state motion (`j`/`k`/`gg`/`C-d`/`C-u`) works in both
read-only buffers. Attach files with `Attach: /path/to/file` header lines in
the compose buffer. `s` takes Gmail's query syntax on both backends
(REST `q=` / IMAP `X-GM-RAW`); an empty query returns to the inbox. `f` opens
a magit-style folder popup — Inbox, Unread, Starred, Sent, All Mail, Trash,
or an ad-hoc search — and `i` jumps straight back to the inbox. The list
header shows the active account (when more than one is configured), its
address, auth method, and any queued flag ops.

## Live vs. offline mode

The `email-mode` option (or the `M` toggle in the `?`/folder menus) picks how
the client treats the network:

| | `live` (default) | `offline` |
|---|---|---|
| Message bodies | downloaded lazily when you open one | **sync downloads every new body** so the whole inbox reads disconnected |
| Opening a message | fetches if not cached | local files only — never hits the network |
| Composing / sending | sent immediately | **queued to the outbox**; sent later with `email-outbox-flush` |
| Search `s` | server-side Gmail query | redirects to local FTS search |
| Folders | Sent/All Mail/Trash query the server | those report "needs a connection"; Inbox/Unread/Starred are local |

Offline mode does **not** mean "never connect" — `G` (sync) and flushing the
outbox are the deliberate network actions. It means the *passive* surface
(reading, searching, browsing) stays entirely on local files, so the workflow
is: sync while you have a connection, then read and reply on the plane, then
`email-outbox-flush` when you land.

The **outbox** (`O`) lists queued messages; `enter` loads one back into a
compose buffer to edit, `d` deletes it, `S` (or `email-outbox-flush`) sends
them all — reporting `N sent, M failed (kept)`, so a partial failure never
drops mail. Queued files live in `<account>/outbox/*.eml` (compose-format
text plus the threading headers) and persist across restarts. As a safety
net this applies in **live mode too**: if a send hits a dropped connection,
the message is queued rather than lost.

Attachments are always fetched on demand, so they need a connection even in
offline mode (the view says so). The list header shows `OFFLINE` and the
outbox count when either applies.

## How it works

- **Accounts**: one account is active at a time; switching (`a`) saves the
  current account's store, swaps in the other's, and re-renders. Compose,
  sync, search, and flag ops always run against the active account. Switching
  is refused mid-sync/mid-login so in-flight work can't cross accounts.
- **Store** (shared format across both methods): the per-account `index`
  holds one envelope per line with both backends' sync baselines on its
  header line; `messages/<id>` files carry an attachment manifest tagged with
  which backend wrote it — a cache from the other backend is refreshed
  transparently.
- **Flag changes** (read/star/archive/trash) apply locally at once and queue
  as backend-neutral `(id . kind)` pending ops; whichever backend syncs next
  replays them (REST `modify`/`trash`, or IMAP `STORE`/`MOVE` located by
  `X-GM-MSGID`). They survive restarts, offline periods, and method changes.
- **Codec**: RFC 2047 headers, charset-labeled bodies (`decode-charset`),
  full RFC 822/MIME parsing for the IMAP path, REST's pre-parsed JSON for the
  OAuth path, and MIME assembly for send (attachments, encoded subjects, Bcc
  handled per transport).
- **HTML rendering**: text/html-only mail goes through a vendored copy of the
  macros-web-reader layout engine — reader-mode chrome removal, nested lists
  with indentation, `│`-barred blockquotes, `#` headings, preserved `<pre>`,
  and links lifted to `[N]` markers with a numbered URL footer. A lightweight
  tag-stripper remains as the fallback for pathological input.
- **Privacy**: rendering HTML mail makes **no network connections**. Remote
  images are never fetched — `<img>` contributes only its alt text, so
  tracking pixels and read receipts stay inert. Links render as `[N]`
  markers; `enter` (or a click) on one opens it in your default browser —
  always an explicit user action on a visible marker, never automatic. The
  only other browser-openers are the OAuth login flow and the `b` key.
- **Compose**: `C-c C-a` opens a file picker and adds an `Attach:` header
  line (or type one yourself); `C-c C-b` adds a `Bcc:` header. On the
  To/Cc/Bcc lines, addresses autocomplete (`M-i`, and the automatic
  completion chain) from every correspondent in the account's local index —
  the token replaced is the whole address, dots and `@` included.

## Exporting to mu / notmuch (Maildir)

`M-x email-export-maildir` downloads the account's **entire mailbox** as a
Maildir of byte-exact RFC 822 files — the format `mu` and `notmuch` index.
It prompts for a destination (default `<account-dir>/maildir`) and writes
`cur/<epoch>.<id>.macros:2,<flags>`, with Gmail labels mapped to Maildir
info flags (`S` read, `F` starred, `D` draft, `T` trashed).

- **Resumable / incremental**: exported ids persist in `.macros-exported`;
  re-running skips them and downloads only new mail.
- **OAuth accounts** export asynchronously — the editor stays usable, and
  `M-x email-export-cancel` stops between messages. **App-password accounts**
  export over blocking IMAP (fine for small boxes; prefer oauth for a large
  first run).
- **Automatic mirroring**: set the `email-maildir` option to a directory and
  every sync ends by writing the newly-arrived messages into it (a manifest
  diff, so a missed run self-heals on the next sync). Do one manual
  `email-export-maildir` first for the historical backfill; the option keeps
  it current from then on. Run `mu index` / `notmuch new` on your own
  schedule (cron, or a macros `run-with-timer`).

  ```scheme
  (set-option "email-maildir" "~/.macros-email/personal/maildir")
  ```

- Then point your indexer at it:

  ```
  mu init --maildir=$HOME/.macros-email/<account>/maildir && mu index
  # or
  notmuch config set database.path $HOME/.macros-email/<account>/maildir
  notmuch new
  ```

## Local full-text search (the package's own index)

Instead of `mu index`, the package builds and owns its own search index:

- **`M-x email-index`** (or `f` → `x`) builds a **SQLite FTS5** index over the
  account's Maildir at `<account-dir>/search.db` — BM25-ranked, offline, over
  the whole archive. It's **incremental**: re-running only adds new files, so
  pair it with the auto-mirror (`email-maildir`) and re-run whenever you like
  (manually, or from a macros `run-with-timer`).
- **`M-x email-search-local`** (or `/`, or `f` → `/`) queries it. Bare words
  match anywhere; `from:`, `to:`, `subject:` are column filters; FTS5 phrase
  (`"..."`), prefix (`pay*`), boolean (`AND`/`OR`/`NOT`), and `NEAR()` syntax
  all work — e.g. `from:kim invoice NEAR(payment overdue)`. Results pin as a
  folder view; hits older than your synced window are pulled from the Maildir
  so they still render.

Requires a Maildir first (`M-x email-export-maildir`, or the auto-mirror
option). This uses the generic `sqlite-*` primitives added to macros, so the
index is a normal SQLite database — inspectable with any SQLite tool.

## Applying emailed patches (git am)

If you receive patches by email (the `git send-email` / `git format-patch`
workflow), the message view's `?` menu has a **Patch / git** group — the raw
RFC 822 message *is* what `git am` consumes, so a patch series in your inbox
becomes commits without leaving the editor:

- **git am (apply)** — prompts for a repo and applies the message as a commit.
- **git am --3way** — same, with a 3-way merge fallback when the patch
  doesn't apply cleanly.
- **git am --abort** — unwind a series that failed partway.
- **Save .patch** — write the raw message to a file for `git am` later or
  archiving.

Set `email-git-repo` to a default repo so you don't retype the path:

```scheme
(set-option "email-git-repo" "~/src/linux")
```

Patches are fetched raw (`format=raw` on OAuth, `BODY.PEEK[]` on IMAP),
written to a temp file, and applied by shelling out to the real `git`
(`git -C <repo> am <file>`) — not a library reimplementation, since `git am`
is a stateful porcelain command. The repo path must be **absolute** (a
leading `~/` is expanded); relative paths are rejected, because a GUI-launched
editor's working directory isn't your project. The result (or git's own
error) shows in the echo area.

## Limitations

- Google-only: the REST path by definition; the IMAP path leans on Gmail's
  `X-GM-*` extensions. (STARTTLS-capable `tcp-connect`/`tls-upgrade`
  primitives exist in macros for a future generic-IMAP backend.)
- The `email-name` display name, GCP client, and query options are global,
  not per-account.
- The IMAP backend's sync/search/open are blocking (a second or two); the
  OAuth backend is fully async.
- `text/plain` preferred; HTML-only mail renders through the vendored
  layout engine (text, not a browser) — `b` opens the real thing. Send is
  text + attachments.
