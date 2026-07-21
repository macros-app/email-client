;; macros-email-client — a mu4e-style Gmail client for the macros editor, in
;; Steel, with pluggable authentication: OAuth (Gmail REST API) or an app
;; password (real IMAP/SMTP).
;;
;; Set the "email-auth-method" option to pick the backend:
;;
;;   "oauth"        (default) — OAuth 2.0 + PKCE against your own GCP Desktop
;;                  client (loopback `http-serve` redirect, refresh token in
;;                  the keychain). Transport is the Gmail REST API over the
;;                  editor's async `http-request`: incremental history.list
;;                  sync, messages.send, server-side q= search.
;;   "app-password" — your address + a Gmail app password (needs 2-Step
;;                  Verification; myaccount.google.com/apppasswords). Transport
;;                  is real IMAP (993) + SMTP (465) over the blocking `tls-*`
;;                  primitives: UID/UIDVALIDITY incremental sync, Gmail's
;;                  X-GM-MSGID/THRID/LABELS/RAW extensions, SMTP submission.
;;
;; The two backends SHARE ONE LOCAL STORE. Gmail's REST message id is the hex
;; form of IMAP's X-GM-MSGID, so the IMAP backend hex-normalizes its ids and
;; the index, message cache, read/star state, and pending flag ops all survive
;; switching "email-auth-method" — log in once per method and flip freely.
;;
;;   * store   — <data-dir>/index: one line per message (US-separated fields;
;;               both backends' sync baselines ride the header line).
;;               <data-dir>/messages/<id>: decoded headers + body text with an
;;               attachment manifest; attachment bytes are fetched lazily.
;;   * flags   — read/star/archive/trash apply locally at once and queue as
;;               (id . kind) pending ops, persisted to disk; each sync replays
;;               them through whichever backend is active.
;;   * codec   — RFC 822/2047/MIME parsing and assembly live here: folded
;;               headers, multipart trees (with IMAP section numbering),
;;               base64 + quoted-printable, charset-labeled bodies through the
;;               generic `decode-charset` primitive.
;;
;;   M-x email  /  C-c m      open the message list
;;
;;   in *email* (list):
;;     enter            open the message (marks it read; clicks only move
;;                      the cursor — no accidental opens)
;;     C                compose a new message
;;     R                reply to the message at point
;;     A                archive (remove from inbox)
;;     D                move to Gmail trash
;;     U                toggle read/unread
;;     *                toggle star
;;     s                server-side search (Gmail query syntax); empty resets
;;     g                redraw from the local store
;;     G                sync with Gmail (also replays queued flag changes)
;;     L                log in (first run; flow depends on the auth method)
;;     q                bury the buffer
;;
;;   in *email-view*:
;;     n / p            next / previous message in the list
;;     R / A / D        reply / archive / trash this message
;;     W                save an attachment (by number)
;;     b                open this message in the Gmail web UI
;;     q                back to the list
;;
;;   in *email-compose*:
;;     C-c C-c          send        C-c C-k  discard
;;     add `Attach: /path/to/file` header lines to attach files
;;
;; Configuration happens through OPTIONS from init.scm (the k8s/feeds pattern
;; — a package's globals aren't reachable from the init compile unit):
;;
;;   (package-install-local "~/workspace/macros-email-client"
;;     'config (lambda ()
;;               ;; One entry per mailbox, whitespace-separated "name|method"
;;               ;; (method: oauth | app-password). Each account gets its own
;;               ;; store under <email-data-dir>/<name>/ and its own keychain
;;               ;; credential. `a` in *email* cycles accounts;
;;               ;; M-x email-switch-account prompts by name.
;;               (set-option "email-accounts" "personal|oauth work|app-password")
;;               ;; oauth accounts (one GCP client covers all of them):
;;               (set-option "email-client-id"     "…apps.googleusercontent.com")
;;               (set-option "email-client-secret" "…")
;;               ;; …or keep secrets OUT of init.scm entirely: ~/.authinfo
;;               ;; (netrc format, .gpg supported) — see the authinfo section.
;;               (set-option "email-query"         "in:inbox")  ; REST sync scope
;;               ;; shared:
;;               (set-option "email-fetch-count"   "100")       ; first-sync size
;;               (set-option "email-name"          "Kyle Gwinnup")
;;               (set-option "email-auto-sync-minutes" "5")))   ; unset = manual G
;;
;; With no "email-accounts" set, a single account named "default" uses the
;; "email-auth-method" option (default "oauth") — the pre-multi-account
;; behavior. See the README for the per-method setup walkthroughs and the
;; on-disk layout.
;;
;; Everything here is self-contained: editor primitives, Steel builtins, and
;; core.scm (always loaded). No other packages required.

;; ── configuration ───────────────────────────────────────────────────────────
(define *email-data-dir* (string-append (getenv "HOME") "/.macros-email"))
(define *email-from-width* 22)      ; list column width, chars
(define *email-subject-width* 64)
(define *email-view-width* 100)     ; view-buffer wrap width

;; ── state ───────────────────────────────────────────────────────────────────
;; All mutable runtime state in ONE global hash (the feeds/web-reader pattern).
;; Every key is seeded so #f always means "the value is #f", never "missing".
(define *email-state*
  (hash
   'db           (hash)  ; id (hex X-GM-MSGID = REST id) → envelope hash
   'ids          '()     ; every id, insertion order (drives persistence)
   'loaded       #f      ; index file has been read this session
   'history-id   ""      ; REST history baseline; "" = full sync needed
   'uid-validity ""      ; IMAP INBOX UIDVALIDITY; change forces refetch
   'max-uid      0       ; IMAP incremental high-water mark
   'me           ""      ; the account address
   'view         '()     ; ids currently rendered in *email*, display order
   'view-offset  3       ; buffer line of the first message row
   'view-atts    '()     ; attachments of the message shown in *email-view*
   'view-lines   '()     ; rendered lines of *email-view* (link hit-testing)
   'view-links   '()     ; (number . url) alist from the message's link footer
   'current      #f      ; id shown in *email-view*
   'search-ids   #f      ; ids of the active server search, or #f = inbox view
   'folder       #f      ; display name of the pinned folder/search, #f = inbox
   'ops          '()     ; queued REST op thunks (one http chain at a time)
   'busy         #f      ; a REST op chain is in flight
   'http-k       #f      ; continuation for the single named http callback
   'imap-tag     0       ; monotonic IMAP command tag counter
   'fetchq       '()     ; ids awaiting a REST envelope fetch
   'new-count    0       ; messages added by the running sync
   'syncing      #f
   'auth         #f      ; in-flight oauth: hash 'verifier 'state 'port
   'access-token #f
   'token-expiry 0       ; epoch seconds the access token dies
   'refresh-token #f
   'token-loaded #f      ; keychain consulted for the refresh token
   'app-pass     #f
   'pass-loaded  #f      ; keychain consulted for the app password
   'pending-ops  '()     ; (id . kind) flag ops awaiting replay
   'mode         #f      ; runtime mode override: #f = use option | 'live | 'offline
   'cacheq       '()     ; ids awaiting eager body download (offline sync)
   'caching      #f      ; an eager-cache pass is in flight
   'outbox-files '()     ; filenames rendered in *email-outbox*
   'exporting    #f      ; Maildir export: #f | 'run | 'cancel
   'indexing     #f      ; local FTS index build: #f | 'run | 'cancel
   'index-db     #f      ; open sqlite handle for the running build
   'index-files  '()     ; maildir files still to index this build
   'index-existing (hash); ids already in the db (incremental skip set)
   'index-new    0       ; rows inserted this build
   'index-total  0       ; total maildir files this build
   'export-dir   ""      ; destination Maildir root
   'export-queue '()     ; ids of the current REST page awaiting fetch
   'export-token ""      ; next messages.list pageToken
   'export-count 0       ; files written this export
   'export-skip  0       ; ids already present (manifest hits)
   'export-seen  (hash)  ; id → #t, everything ever exported here
   'export-old   '()     ; manifest ids loaded from disk
   'export-new   '()     ; ids exported this run (appended to the manifest)
   'export-quiet #f      ; auto-mirror run: suppress the no-op summary
   'account      #f      ; active account name; #f = first configured
   'timer-armed  #f
   'tz           #f))    ; local UTC offset seconds, computed once

(define (em--st key)    (hash-try-get *email-state* key))
(define (em--st! key v) (set! *email-state* (hash-insert *email-state* key v)))

;; A config knob: the named option when set to a string, else the fallback.
(define (em--knob opt fallback)
  (let ((v (get-option opt)))
    (if (string? v) v fallback)))

(define (em--expand-home p)
  (if (and (> (string-length p) 1) (equal? (substring p 0 2) "~/"))
      (string-append (getenv "HOME") (substring p 1 (string-length p)))
      p))

;; ── accounts ────────────────────────────────────────────────────────────────
;; The "email-accounts" option is an ARRAY OF ACCOUNT CONFIGURATIONS — a plain
;; Scheme LIST OF HASHES, one self-contained config per mailbox:
;;
;;   (set-option "email-accounts"
;;     (list (hash 'name "me@gmail.com" 'method "oauth"
;;                 'client-id "…" 'client-secret "…")
;;           (hash 'name "work@corp.com" 'method "app-password"
;;                 'query "in:inbox")))
;;
;; Recognized fields (all optional except name): method, client-id,
;; client-secret, query, address, from-name, imap-host, smtp-host, mode,
;; maildir, fetch-count, auto-sync-minutes. Any omitted field falls back to the
;; matching global "email-<field>" option, then a built-in default — so shared
;; settings stay global and only per-mailbox differences go in the hash.
;;
;; Still accepted for simple setups: the legacy whitespace-separated
;; "name|method" string. Unset → one account "default" using
;; "email-auth-method". Each account owns a data-dir subdirectory and its own
;; keychain credential; ONE is active at a time, and switching saves + swaps
;; the store.
;; Parse the option VALUE into a list of account hashes (split out so it's
;; testable without the editor's option store). '() when unset/empty.
(define (em--parse-accounts v)
  (cond
    ;; A Scheme list of account hashes (the canonical form).
    ((and (list? v) (pair? v))
     (map (lambda (o) (if (hash? o) o (hash 'name (em--jstr o)))) v))
    ;; A non-empty string → the legacy "name|method …" shorthand.
    ((and (string? v) (not (equal? (em--trim v) "")))
     (map (lambda (tok)
            (let ((parts (em--split-char tok #\|)))
              (hash 'name (car parts)
                    'method (if (and (pair? (cdr parts)) (not (equal? (car (cdr parts)) "")))
                                (car (cdr parts)) "oauth"))))
          (filter (lambda (t) (not (equal? t "")))
                  (em--split-char (replace-regexp-in-string "\\s+" " " (em--trim v)) #\space))))
    (else '())))

;; ~/.config/macros/email-client.conf — a Scheme file written by the
;; M-x email-add-account wizard and freely hand-editable. It must evaluate
;; to a list of account hashes (same fields as "email-accounts"); its
;; entries are merged over the option's list, keyed by 'name.
(define (em--conf-file) "~/.config/macros/email-client.conf")

(define (em--conf-accounts)
  (let ((path (em--expand-home (em--conf-file))))
    (if (not (file-exists? path)) '()
        (let ((v (with-handler
                  (lambda (e)
                    (message (string-append "email: " (em--conf-file)
                                            " failed to evaluate — fix it or delete it"))
                    '())
                  (eval-string (read-file path)))))
          (if (list? v) (filter hash? v) '())))))

;; Overlay `extra` onto `base`: an entry whose 'name already exists replaces
;; it in place; a new 'name appends. Order of `base` is preserved.
(define (em--merge-accounts base extra)
  (let loop ((es extra) (acc base))
    (if (null? es) acc
        (loop (cdr es)
              (let* ((e (car es)) (n (em--acc-name e)))
                (let sub ((as acc) (out '()) (found #f))
                  (cond ((null? as) (reverse (if found out (cons e out))))
                        ((equal? (em--acc-name (car as)) n)
                         (sub (cdr as) (cons e out) #t))
                        (else (sub (cdr as) (cons (car as) out) found)))))))))

(define (em--accounts)
  (let ((merged (em--merge-accounts
                 (em--parse-accounts (get-option "email-accounts"))
                 (em--conf-accounts))))
    (if (null? merged)
        (list (hash 'name "default" 'method (em--knob "email-auth-method" "oauth")))
        merged)))

(define (em--acc-name a) (em--jstr (hash-try-get a 'name)))

;; The active account name (first configured until a switch).
(define (em--account)
  (or (em--st 'account)
      (let ((name (em--acc-name (car (em--accounts)))))
        (em--st! 'account name)
        name)))

;; The active account's config object (a bare {name} hash if not found).
(define (em--account-rec)
  (let ((name (em--account)))
    (let loop ((as (em--accounts)))
      (cond ((null? as) (hash 'name name))
            ((equal? (em--acc-name (car as)) name) (car as))
            (else (loop (cdr as)))))))

;; Does an account named `name` exist in the config?
(define (em--account-exists? name)
  (let loop ((as (em--accounts)))
    (cond ((null? as) #f)
          ((equal? (em--acc-name (car as)) name) #t)
          (else (loop (cdr as))))))

;; A per-account setting: the active account object's `field` (a non-empty
;; string), else the global "email-<…>" option, else `fallback`.
(define (em--acct field global-opt fallback)
  (let ((v (hash-try-get (em--account-rec) field)))
    (if (and (string? v) (not (equal? (em--trim v) ""))) v
        (em--knob global-opt fallback))))

(define (em--data-dir)      (em--expand-home (em--knob "email-data-dir" *email-data-dir*)))
(define (em--acct-dir)      (path-join (em--data-dir) (em--account)))
(define (em--index-file)    (path-join (em--acct-dir) "index"))
(define (em--pending-file)  (path-join (em--acct-dir) "pending"))
(define (em--token-file)    (path-join (em--acct-dir) "token"))
(define (em--pass-file)     (path-join (em--acct-dir) "app-password"))
(define (em--messages-dir)  (path-join (em--acct-dir) "messages"))
(define (em--msg-file id)   (path-join (em--messages-dir) id))
;; OAuth client credentials: account hash → global option → authinfo
;; (machine = account name, login = the field; see the authinfo section).
(define (em--client-id)
  (let ((v (em--trim (em--acct 'client-id "email-client-id" ""))))
    (if (equal? v "") (or (em--authinfo-find (em--account) "client-id") "") v)))
(define (em--client-secret)
  (let ((v (em--trim (em--acct 'client-secret "email-client-secret" ""))))
    (if (equal? v "") (or (em--authinfo-find (em--account) "client-secret") "") v)))
(define (em--query)         (em--acct 'query "email-query" "in:inbox"))
(define (em--imap-host)     (em--acct 'imap-host "email-imap-host" "imap.gmail.com"))
(define (em--smtp-host)     (em--acct 'smtp-host "email-smtp-host" "smtp.gmail.com"))
(define (em--fetch-count)
  (let ((n (string->number (em--acct 'fetch-count "email-fetch-count" "100"))))
    (if (and n (> n 0) (<= n 500)) n 100)))

;; The ACTIVE ACCOUNT's auth method: 'oauth or 'app-password (an unrecognized
;; value falls back to oauth, with the misspelling surfaced).
(define (em--method)
  (let ((m (em--downcase (em--trim (em--acct 'method "email-auth-method" "oauth")))))
    (cond ((equal? m "app-password") 'app-password)
          ((equal? m "oauth") 'oauth)
          (else (message (string-append "email: unknown auth method \"" m "\" — using oauth"))
                'oauth))))

(define (em--oauth?) (equal? (em--method) 'oauth))

;; ── live / offline mode ─────────────────────────────────────────────────────
;; live (default): bodies download lazily on open; send goes out immediately.
;; offline: sync eagerly downloads every new message's body so the UI is fully
;; usable disconnected; opening never hits the network (local files only);
;; composing queues into the outbox, flushed manually with `email-outbox-flush`
;; when connected. The `email-mode` option sets the startup mode; the runtime
;; override (email-toggle-mode) wins for the session. Note: sync and outbox
;; flush ARE the network actions — offline means the PASSIVE surface (open,
;; search, attachments) stays local, not that nothing ever connects.
(define (em--mode)
  (or (em--st 'mode)
      (if (equal? (em--downcase (em--trim (em--acct 'mode "email-mode" "live"))) "offline")
          'offline 'live)))

(define (em--offline?) (equal? (em--mode) 'offline))

(define em--all-mail "[Gmail]/All Mail")
(define em--trash-box "[Gmail]/Trash")

;; ── tiny helpers (self-contained, byte/char-safe) ───────────────────────────
(define (em--trim s) (replace-regexp-in-string "^\\s+|\\s+$" "" s))
(define (em--trim-crlf s) (replace-regexp-in-string "[\r\n]+$" "" s))

;; Split `s` on every occurrence of the single character `ch`. Delegates to the
;; native `split-many` (a literal, byte-safe Rust split) instead of a Steel
;; char-list walk: the old walk was O(n) with a large per-char constant, which
;; made MIME parsing of a large message (`em--mime-leaves` splits the whole
;; body, once per nesting level) take SECONDS — a 912 KB message went 277 ms →
;; 3 ms here, and a whole-archive index that had frozen the UI (C-g/`q`
;; unresponsive) is now responsive. `split-many` matches this function's
;; semantics exactly on empty/leading/trailing/consecutive delimiters, and its
;; delimiter is literal (no regex), so control-char field separators split fine.
(define (em--split-char s ch)
  (split-many s (list->string (list ch))))

;; UTF-8 byte length of `s` — overlay spans are byte-based.
(define (em--bytelen s)
  (let loop ((cs (string->list s)) (n 0))
    (if (null? cs)
        n
        (let ((cp (char->integer (car cs))))
          (loop (cdr cs)
                (+ n (cond ((< cp 128) 1) ((< cp 2048) 2) ((< cp 65536) 3) (else 4))))))))

;; First capture group of `pat` in `s`, or #f. Captures return STRINGS — the
;; only regex result safe to combine with char-indexed operations.
(define (em--cap pat s)
  (let ((c (regexp-captures pat s)))
    (if (null? c) #f (nth c 1))))

(define (em--matches? pat s) (not (null? (regexp-captures pat s))))

(define (em--concat xs)
  (let loop ((xs xs) (acc "")) (if (null? xs) acc (loop (cdr xs) (string-append acc (car xs))))))

(define (em--join xs sep)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) sep (em--join (cdr xs) sep)))))

;; Pad/truncate `s` to exactly `w` display chars.
(define (em--fit s w)
  (let ((n (string-length s)))
    (cond ((> n w) (substring s 0 w))
          ((= n w) s)
          (else (let loop ((s s) (n n))
                  (if (= n w) s (loop (string-append s " ") (+ n 1))))))))

(define (em--truncate s w)
  (if (> (string-length s) w) (string-append (substring s 0 (- w 1)) "…") s))

(define (em--downcase s)
  (list->string
   (map (lambda (c)
          (let ((i (char->integer c)))
            (if (and (>= i 65) (<= i 90)) (integer->char (+ i 32)) c)))
        (string->list s))))

(define (em--ascii? s)
  (let loop ((cs (string->list s)))
    (cond ((null? cs) #t)
          ((>= (char->integer (car cs)) 128) #f)
          (else (loop (cdr cs))))))

;; Field separators for store files, plus the regex fence sentinel.
(define em--us  (list->string (list (integer->char 31))))
(define em--rs-ch (integer->char 30))
(define em--rs  (list->string (list em--rs-ch)))
(define em--soh (integer->char 1))
(define em--soh-str (list->string (list em--soh)))

;; Strip control chars that would corrupt a store line; newlines → spaces.
(define (em--sanitize s)
  (list->string
   (map (lambda (c) (if (< (char->integer c) 32) #\space c))
        (string->list s))))

;; Body text cleanup: keep newlines and tabs, drop \r and other control chars.
(define (em--body-clean s)
  (list->string
   (map (lambda (c)
          (let ((i (char->integer c)))
            (if (and (< i 32) (not (= i 10)) (not (= i 9))) #\space c)))
        (string->list (replace-regexp-in-string "\r" "" s)))))

(define em--hex-digits "0123456789abcdef")
(define (em--hex2 n)              ; byte → two lowercase hex chars
  (string-append (substring em--hex-digits (quotient n 16) (+ 1 (quotient n 16)))
                 (substring em--hex-digits (modulo n 16) (+ 1 (modulo n 16)))))

(define (em--hexval s)            ; hex string → integer
  (let loop ((cs (string->list s)) (acc 0))
    (if (null? cs)
        acc
        (let* ((i (char->integer (car cs)))
               (v (cond ((and (>= i 48) (<= i 57)) (- i 48))
                        ((and (>= i 97) (<= i 102)) (- i 87))
                        ((and (>= i 65) (<= i 70)) (- i 55))
                        (else 0))))
          (loop (cdr cs) (+ (* acc 16) v))))))

;; Decimal digit string → lowercase hex string, by repeated division on the
;; digit sequence — X-GM-MSGID/THRID are uint64, past float precision, and the
;; hex form IS the Gmail REST id, which is why both backends share one id
;; space. ("1278455344230334865" → "11bdfc5cae0c8191".)
(define (em--dec->hex s)
  (if (or (not s) (equal? s ""))
      ""
      (let loop ((digits (map (lambda (c) (- (char->integer c) 48)) (string->list s)))
                 (out '()))
        (let div ((ds digits) (q '()) (rem 0))
          (if (null? ds)
              (let ((h (substring em--hex-digits rem (+ 1 rem)))
                    (q (let strip ((xs (reverse q)))
                         (if (and (pair? xs) (= (car xs) 0) (pair? (cdr xs)))
                             (strip (cdr xs))
                             xs))))
                (if (equal? q '(0))
                    (em--concat (cons h out))
                    (loop q (cons h out))))
              (let ((cur (+ (* rem 10) (car ds))))
                (div (cdr ds) (cons (quotient cur 16) q) (modulo cur 16))))))))

;; The reverse bridge (hex → decimal digits) for X-GM-MSGID SEARCH, which
;; takes the DECIMAL form: out = out*16 + nibble on a decimal digit list.
(define (em--hex->dec h)
  (if (equal? h "")
      ""
      (let loop ((cs (string->list (em--downcase h))) (out '(0)))
        (if (null? cs)
            (em--concat (map number->string out))
            (let* ((i (char->integer (car cs)))
                   (v (cond ((and (>= i 48) (<= i 57)) (- i 48))
                            ((and (>= i 97) (<= i 102)) (- i 87))
                            (else 0)))
                   (next (let mul ((ds (reverse out)) (carry v) (acc '()))
                           (if (null? ds)
                               (if (= carry 0)
                                   acc
                                   (let split ((c carry) (acc acc))
                                     (if (= c 0) acc (split (quotient c 10) (cons (modulo c 10) acc)))))
                               (let ((cur (+ (* (car ds) 16) carry)))
                                 (mul (cdr ds) (quotient cur 10) (cons (modulo cur 10) acc)))))))
              (loop (cdr cs) next))))))

;; A byte-preserving (latin-1) string — what the socket primitives return — to
;; hex, ready for `decode-charset`/`write-file-hex`.
(define (em--latin1->hex s)
  (em--concat
   (map (lambda (c)
          (let ((i (char->integer c)))
            (em--hex2 (if (< i 256) i 63))))
        (string->list s))))

;; ── URL + form encoding (oauth flow, web links) ─────────────────────────────
(define (em--urlenc s)
  (em--concat
   (map (lambda (c)
          (let ((i (char->integer c)))
            (cond
              ((or (and (>= i 97) (<= i 122)) (and (>= i 65) (<= i 90))
                   (and (>= i 48) (<= i 57))
                   (= i 45) (= i 46) (= i 95) (= i 126))
               (list->string (list c)))
              ((< i 128) (string-append "%" (em--hex2 i)))
              ((< i 2048)
               (string-append "%" (em--hex2 (+ 192 (quotient i 64)))
                              "%" (em--hex2 (+ 128 (modulo i 64)))))
              (else
               (string-append "%" (em--hex2 (+ 224 (quotient i 4096)))
                              "%" (em--hex2 (+ 128 (modulo (quotient i 64) 64)))
                              "%" (em--hex2 (+ 128 (modulo i 64))))))))
        (string->list s))))

;; Percent-decode (ASCII payloads: OAuth codes and states).
(define (em--urldec s)
  (let loop ((cs (string->list s)) (acc '()))
    (cond
      ((null? cs) (list->string (reverse acc)))
      ((and (char=? (car cs) #\%) (pair? (cdr cs)) (pair? (cdr (cdr cs))))
       (loop (cdr (cdr (cdr cs)))
             (cons (integer->char
                    (em--hexval (list->string (list (nth cs 1) (nth cs 2)))))
                   acc)))
      ((char=? (car cs) #\+) (loop (cdr cs) (cons #\space acc)))
      (else (loop (cdr cs) (cons (car cs) acc))))))

;; Build "k=v&k=v" from a flat (k v k v …) list, url-encoding values.
(define (em--form kvs)
  (let loop ((kvs kvs) (acc '()))
    (if (or (null? kvs) (null? (cdr kvs)))
        (em--join (reverse acc) "&")
        (loop (cdr (cdr kvs))
              (cons (string-append (car kvs) "=" (em--urlenc (car (cdr kvs)))) acc)))))

;; Value of `key` in an http-serve target like "/?code=…&state=…", or "".
(define (em--query-param target key)
  (let* ((q (let ((parts (em--split-char target #\?)))
              (if (null? (cdr parts)) "" (em--join (cdr parts) "?"))))
         (pairs (em--split-char q #\&)))
    (let loop ((ps pairs))
      (if (null? ps)
          ""
          (let ((kv (em--split-char (car ps) #\=)))
            (if (and (equal? (car kv) key) (pair? (cdr kv)))
                (em--urldec (car (cdr kv)))
                (loop (cdr ps))))))))

;; ── time ────────────────────────────────────────────────────────────────────
(define (em--now) (or (string->number (current-time "%s")) 0))

(define (em--epoch y mo d h mi sec)
  (+ (* 86400 (ymd->days y mo d)) (* 3600 h) (* 60 mi) sec))

;; Local UTC offset in seconds, computed once: interpret the local wall clock
;; as if it were UTC and diff against the true epoch (rounded to a minute).
(define (em--tz-offset)
  (or (em--st 'tz)
      (let* ((now (em--now))
             (p (em--split-char (current-time "%Y|%m|%d|%H|%M|%S") #\|))
             (loc (em--epoch (string->number (nth p 0)) (string->number (nth p 1))
                             (string->number (nth p 2)) (string->number (nth p 3))
                             (string->number (nth p 4)) (string->number (nth p 5))))
             (off (* 60 (exact (round (/ (- loc now) 60.0))))))
        (em--st! 'tz off)
        off)))

;; "2026-07-17 09:15" (local time) — 16 ASCII chars, so 16 bytes in overlays.
(define (em--date16 epoch)
  (let* ((t (+ epoch (em--tz-offset)))
         (ymd (days->ymd (quotient t 86400)))
         (secs (modulo t 86400)))
    (string-append (number->string (car ymd)) "-" (pad2 (car (cdr ymd))) "-"
                   (pad2 (car (cdr (cdr ymd)))) " "
                   (pad2 (quotient secs 3600)) ":" (pad2 (quotient (modulo secs 3600) 60)))))

(define em--months
  '(("Jan" . 1) ("Feb" . 2) ("Mar" . 3) ("Apr" . 4) ("May" . 5) ("Jun" . 6)
    ("Jul" . 7) ("Aug" . 8) ("Sep" . 9) ("Oct" . 10) ("Nov" . 11) ("Dec" . 12)))

(define (em--aget amap key)
  (cond ((null? amap) #f)
        ((equal? (car (car amap)) key) (cdr (car amap)))
        (else (em--aget (cdr amap) key))))

;; IMAP INTERNALDATE ("17-Jul-2026 09:15:02 +0000") → epoch seconds, 0 if odd.
(define (em--parse-internaldate s)
  (let ((c (regexp-captures
            "([0-9 ]?[0-9])-([A-Za-z]{3})-([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})" s)))
    (if (null? c)
        0
        (let* ((d (or (string->number (em--trim (nth c 1))) 1))
               (mo (or (em--aget em--months (nth c 2)) 1))
               (y (or (string->number (nth c 3)) 1970))
               (h (or (string->number (nth c 4)) 0))
               (mi (or (string->number (nth c 5)) 0))
               (sec (or (string->number (nth c 6)) 0))
               (offs (+ (* 3600 (or (string->number (nth c 8)) 0))
                        (* 60 (or (string->number (nth c 9)) 0))))
               (offs (if (equal? (nth c 7) "-") (- 0 offs) offs)))
          (- (em--epoch y mo d h mi sec) offs)))))

(define (em--size-string n)
  (cond ((not (number? n)) "?")
        ((< n 1024) (string-append (number->string (exact (round n))) "B"))
        ((< n 1048576) (string-append (number->string (exact (round (/ n 1024.0)))) "K"))
        (else (string-append (number->string (exact (round (/ n 1048576.0)))) "M"))))

;; ── JSON access (string->jsexpr: objects → symbol-keyed hashes) ─────────────
(define (em--j o k) (if (hash? o) (hash-try-get o k) #f))
(define (em--as-list r) (cond ((list? r) r) ((hash? r) (list r)) (else '())))
(define (em--jstr x)
  (cond ((string? x) x)
        ((number? x) (number->string (exact (round x))))
        (else "")))
(define (em--jint x) (if (number? x) (exact (round x)) 0))

;; ── HTML entities ───────────────────────────────────────────────────────────
(define (em--numeric-entities s)
  (let* ((s (replace-regexp-in-string "&#[xX]([0-9a-fA-F]+);"
                                      (string-append em--soh-str "x$1" em--soh-str) s))
         (s (replace-regexp-in-string "&#([0-9]+);"
                                      (string-append em--soh-str "d$1" em--soh-str) s))
         (pieces (em--split-char s em--soh)))
    (let loop ((ps pieces) (i 0) (acc '()))
      (if (null? ps)
          (em--concat (reverse acc))
          (loop (cdr ps) (+ i 1)
                (cons (if (= 0 (modulo i 2))
                          (car ps)
                          (let* ((tok (car ps))
                                 (kind (substring tok 0 1))
                                 (num (substring tok 1 (string-length tok)))
                                 (cp (if (equal? kind "x")
                                         (em--hexval num)
                                         (or (string->number num) 32))))
                            (if (and (> cp 8) (< cp 1114112))
                                (list->string (list (integer->char cp)))
                                " ")))
                      acc))))))

(define (em--entities s)
  (let* ((s (em--numeric-entities s))
         (s (replace-regexp-in-string "&nbsp;" " " s))
         (s (replace-regexp-in-string "&lt;" "<" s))
         (s (replace-regexp-in-string "&gt;" ">" s))
         (s (replace-regexp-in-string "&quot;" "\"" s))
         (s (replace-regexp-in-string "&apos;" "'" s))
         (s (replace-regexp-in-string "&mdash;" "—" s))
         (s (replace-regexp-in-string "&ndash;" "–" s))
         (s (replace-regexp-in-string "&hellip;" "…" s))
         (s (replace-regexp-in-string "&amp;" "&" s)))   ; LAST, or &amp;lt; double-decodes
    s))

;; ── RFC 2047 header decode ──────────────────────────────────────────────────
(define (em--q-word->hex s)
  (let loop ((cs (string->list s)) (acc '()))
    (cond
      ((null? cs) (em--concat (reverse acc)))
      ((char=? (car cs) #\_) (loop (cdr cs) (cons "20" acc)))
      ((and (char=? (car cs) #\=) (pair? (cdr cs)) (pair? (cdr (cdr cs))))
       (loop (cdr (cdr (cdr cs)))
             (cons (em--hex2 (em--hexval (list->string (list (nth cs 1) (nth cs 2))))) acc)))
      (else (loop (cdr cs) (cons (em--hex2 (char->integer (car cs))) acc))))))

(define (em--decode-header s)
  (if (not (em--matches? "=\\?" s))
      s
      ;; Whitespace between adjacent encoded words is transparent (RFC 2047 §6.2).
      (let* ((s (replace-regexp-in-string "\\?=\\s+=\\?" "?==?" s))
             (s (replace-regexp-in-string
                 "=\\?([^? ]+)\\?([bBqQ])\\?([^? ]*)\\?="
                 (string-append em--soh-str "$1" em--us "$2" em--us "$3" em--soh-str) s))
             (pieces (em--split-char s em--soh)))
        (let loop ((ps pieces) (i 0) (acc '()))
          (if (null? ps)
              (em--concat (reverse acc))
              (loop (cdr ps) (+ i 1)
                    (cons
                     (if (= 0 (modulo i 2))
                         (car ps)
                         (let* ((f (em--split-char (car ps) (integer->char 31)))
                                (charset (nth f 0))
                                (kind (em--downcase (nth f 1)))
                                (payload (nth f 2)))
                           (decode-charset
                            (if (equal? kind "b")
                                (base64url-hex payload)
                                (em--q-word->hex payload))
                            charset)))
                     acc)))))))

;; The charset parameter of a Content-Type header value, default utf-8.
(define (em--charset-of content-type)
  (let ((c (em--cap "(?i)charset=\"?([A-Za-z0-9_.:-]+)" (or content-type ""))))
    (if c c "utf-8")))

;; ── base64 bridges ──────────────────────────────────────────────────────────
(define (em--b64swap s)
  (list->string
   (map (lambda (c) (cond ((char=? c #\-) #\+) ((char=? c #\_) #\/) (else c)))
        (string->list s))))

(define (em--b64pad s)
  (let ((r (modulo (string-length s) 4)))
    (cond ((= r 2) (string-append s "=="))
          ((= r 3) (string-append s "="))
          (else s))))

(define (em--b64 s) (em--b64pad (em--b64swap (base64url-encode s))))

(define (em--wrap76 s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (if (>= i n)
          (em--join (reverse acc) "\r\n")
          (let ((end (if (> (+ i 76) n) n (+ i 76))))
            (loop end (cons (substring s i end) acc)))))))

(define (em--b64std-of-string s) (em--wrap76 (em--b64 s)))
(define (em--b64std-of-hex h)    (em--wrap76 (em--b64pad (em--b64swap (hex->base64url h)))))

;; RFC 2047-encode a header value when it isn't plain ASCII.
(define (em--header-word s)
  (if (em--ascii? s)
      s
      (string-append "=?UTF-8?B?" (em--b64 s) "?=")))

;; ── text layout ─────────────────────────────────────────────────────────────
;; Greedy word wrap at `width`, preserving a "> "-style quote prefix.
(define (em--wrap-line line width)
  (let* ((prefix (or (em--cap "^((?:>\\s?)+)" line) ""))
         (body (substring line (string-length prefix) (string-length line)))
         (avail (- width (string-length prefix))))
    (if (<= (string-length line) width)
        (list line)
        (let loop ((ws (filter (lambda (w) (not (equal? w "")))
                               (em--split-char body #\space)))
                   (cur "") (acc '()))
          (cond
            ((null? ws)
             (reverse (if (equal? cur "") acc (cons (string-append prefix cur) acc))))
            ((equal? cur "") (loop (cdr ws) (car ws) acc))
            ((<= (+ (string-length cur) 1 (string-length (car ws))) avail)
             (loop (cdr ws) (string-append cur " " (car ws)) acc))
            (else (loop (cdr ws) (car ws) (cons (string-append prefix cur) acc))))))))

;; The lightweight regex HTML→text pass — the FALLBACK renderer, used when the
;; vendored layout engine below errors on pathological input.
(define (em--html->text-basic html)
  (let* ((s (replace-regexp-in-string "(?is)<(script|style|head)[^>]*>.*?</(script|style|head)>" " " html))
         (s (replace-regexp-in-string "(?i)<br\\s*/?>" "\n" s))
         (s (replace-regexp-in-string "(?i)<li[^>]*>" "\n• " s))
         (s (replace-regexp-in-string "(?i)</(p|div|li|ul|ol|h1|h2|h3|h4|h5|h6|blockquote|tr|pre|table|figure)>" "\n\n" s))
         (s (replace-regexp-in-string "(?i)<(p|h1|h2|h3|h4|h5|h6|blockquote|pre)[^>]*>" "\n\n" s))
         (s (replace-regexp-in-string "(?s)<[^>]*>" " " s))
         (s (em--entities s))
         (s (replace-regexp-in-string "[ \t]+" " " s))
         (s (replace-regexp-in-string "\n\\s*\n(\\s*\n)+" "\n\n" s)))
    (em--body-clean s)))

;; ── vendored HTML layout engine (from macros-web-reader) ────────────────────
;; The web-reader package's reader-mode extraction + indent-aware layout
;; engine, vendored (same author, MIT) so HTML mail renders with real
;; structure — nested lists, blockquote bars, headings, preserved <pre>,
;; numbered links — without a cross-package dependency. Renamed to the
;; `emw--` prefix so loading macros-web-reader alongside never collides.
;; Shared helpers (trim, split-char, aget, entities, hexval) come from this
;; package's own identical definitions.
;;
;; Two passes over a hand-rolled, quote/comment/raw-text-aware tag tokenizer:
;; 'kill removes chrome blocks with correct same-tag nesting; 'keep selects
;; the main content region (<article>, <main>, content-classed containers)
;; with a minimum-text guard — no candidate falls back to the whole cleaned
;; page, which is what most HTML mail is.
;;
;; PRIVACY INVARIANT — this engine makes NO network connections, ever. It is
;; pure string→string processing: <img> tags contribute only their alt TEXT
;; (the src is never read, so tracking pixels and remote images stay inert),
;; <a> hrefs are lifted into plain-text [N] markers and a URL footer, and
;; stylesheets/scripts are dropped whole. Rendered bodies are stored as
;; text, so reopening a message never re-touches its HTML either. A link's
;; URL is opened ONLY by `email-view-follow` — an explicit enter/click on a
;; visible [N] marker — never automatically. Keep it this way: no
;; http-request / socket / open-url / subprocess calls belong anywhere in
;; the emw-- section.
(define emw--void-tags
  (list "area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta"
        "param" "source" "track" "wbr"))
(define emw--raw-tags (list "script" "style" "textarea" "title"))

(define (emw--strip-tags s) (replace-regexp-in-string "(?s)<[^>]*>" "" s))

(define (emw--any? f xs)
  (cond ((null? xs) #f) ((f (car xs)) #t) (else (emw--any? f (cdr xs)))))

;; (emw--rprepend rev out) ≡ (append rev out), but O(|rev|) — appending each
;; tag onto the growing accumulator with `append` would be quadratic.
(define (emw--rprepend rev out)
  (let loop ((xs (reverse rev)) (out out))
    (if (null? xs) out (loop (cdr xs) (cons (car xs) out)))))

(define (emw--tag-char? c)
  (let ((i (char->integer c)))
    (or (and (>= i 97) (<= i 122)) (and (>= i 65) (<= i 90))
        (and (>= i 48) (<= i 57)) (= i 45))))

(define (emw--prefix? p pat)
  (cond ((null? pat) #t)
        ((null? p) #f)
        ((char=? (car p) (car pat)) (emw--prefix? (cdr p) (cdr pat)))
        (else #f)))
(define (emw--drop p n) (if (or (<= n 0) (null? p)) p (emw--drop (cdr p) (- n 1))))
(define (emw--scan-past p pat)
  (cond ((null? p) '())
        ((emw--prefix? p pat) (emw--drop p (length pat)))
        (else (emw--scan-past (cdr p) pat))))

;; Escape '<'/'>' inside quoted attribute values, so later regex passes over
;; the surviving markup can't be derailed by a raw '>' in a value.
(define (emw--push-escaped c raw)
  (cond ((char=? c #\<) (cons #\; (cons #\t (cons #\l (cons #\& raw)))))
        ((char=? c #\>) (cons #\; (cons #\t (cons #\g (cons #\& raw)))))
        (else (cons c raw))))

;; Parse a tag's attribute region into a lowercased (name . value) alist.
(define (emw--parse-attrs s)
  (let loop ((cs (string->list (string-downcase s))) (acc '()))
    (cond
      ((null? cs) (reverse acc))
      ((or (char-whitespace? (car cs)) (char=? (car cs) #\/)) (loop (cdr cs) acc))
      (else
       (let nm ((p cs) (n '()))
         (if (and (pair? p) (not (char-whitespace? (car p)))
                  (not (char=? (car p) #\=)) (not (char=? (car p) #\/)))
             (nm (cdr p) (cons (car p) n))
             (let* ((name (list->string (reverse n)))
                    (p (let sk ((p p))
                         (if (and (pair? p) (char-whitespace? (car p))) (sk (cdr p)) p))))
               (if (and (pair? p) (char=? (car p) #\=))
                   (let ((p (let sk ((p (cdr p)))
                              (if (and (pair? p) (char-whitespace? (car p))) (sk (cdr p)) p))))
                     (cond
                       ((and (pair? p) (or (char=? (car p) #\") (char=? (car p) #\')))
                        (let vq ((q (cdr p)) (v '()))
                          (cond ((null? q)
                                 (loop q (cons (cons name (list->string (reverse v))) acc)))
                                ((char=? (car q) (car p))
                                 (loop (cdr q) (cons (cons name (list->string (reverse v))) acc)))
                                (else (vq (cdr q) (cons (car q) v))))))
                       (else
                        (let vb ((q p) (v '()))
                          (if (and (pair? q) (not (char-whitespace? (car q))))
                              (vb (cdr q) (cons (car q) v))
                              (loop q (cons (cons name (list->string (reverse v))) acc)))))))
                   (loop p (cons (cons name "") acc))))))))))

;; Read ONE markup construct at `cs` (which begins with #\<). Returns
;;   (list kind name attrs selfclosing? raw rest)  — kind ∈ 'open 'close
;; 'skip 'text; `raw` holds the consumed chars REVERSED.
(define (emw--read-tag cs)
  (let ((p (cdr cs)))
    (cond
      ((null? p) (list 'text "" '() #f '() p))
      ((or (char=? (car p) #\!) (char=? (car p) #\?))
       (if (emw--prefix? p (list #\! #\- #\-))
           (list 'skip "" '() #f '() (emw--scan-past (emw--drop p 3) (list #\- #\- #\>)))
           (list 'skip "" '() #f '() (emw--scan-past p (list #\>)))))
      ((char=? (car p) #\/)
       (let nm ((q (cdr p)) (n '()) (raw (list #\/ #\<)))
         (cond
           ((and (pair? q) (emw--tag-char? (car q)))
            (nm (cdr q) (cons (char-downcase (car q)) n) (cons (car q) raw)))
           ((null? n) (list 'skip "" '() #f '() (emw--scan-past p (list #\>))))
           (else
            (let g ((q q) (raw raw))
              (cond ((null? q) (list 'skip "" '() #f '() '()))
                    ((char=? (car q) #\>)
                     (list 'close (list->string (reverse n)) '() #f
                           (cons #\> raw) (cdr q)))
                    (else (g (cdr q) (cons (car q) raw)))))))))
      ((emw--tag-char? (car p))
       (let nm ((q p) (n '()) (raw (list #\<)))
         (if (and (pair? q) (emw--tag-char? (car q)))
             (nm (cdr q) (cons (char-downcase (car q)) n) (cons (car q) raw))
             (let at ((q q) (ac '()) (raw raw) (qch #f))
               (cond
                 ((null? q) (list 'skip "" '() #f '() '()))
                 (qch (at (cdr q) (cons (car q) ac) (emw--push-escaped (car q) raw)
                          (if (char=? (car q) qch) #f qch)))
                 ((or (char=? (car q) #\") (char=? (car q) #\'))
                  (at (cdr q) (cons (car q) ac) (cons (car q) raw) (car q)))
                 ((char=? (car q) #\>)
                  (let* ((name (list->string (reverse n)))
                         (selfc (if (or (and (pair? ac) (char=? (car ac) #\/))
                                        (member name emw--void-tags))
                                    #t #f)))
                    (list 'open name (emw--parse-attrs (list->string (reverse ac)))
                          selfc (cons #\> raw) (cdr q))))
                 (else (at (cdr q) (cons (car q) ac) (cons (car q) raw) #f)))))))
      (else (list 'text "" '() #f '() p)))))

;; Consume raw-text content (<script>/<style>/…) up to and INCLUDING its
;; literal close tag. Returns (rest . out).
(define (emw--scan-raw cs name emit? out)
  (let ((nchars (string->list name)))
    (let loop ((p cs) (out out))
      (cond
        ((null? p) (cons p out))
        ((and (char=? (car p) #\<) (pair? (cdr p)) (char=? (car (cdr p)) #\/))
         (let m ((q (emw--drop p 2)) (nc nchars) (acc (list #\/ #\<)))
           (cond
             ((and (null? nc)
                   (or (null? q) (char=? (car q) #\>) (char-whitespace? (car q))))
              (let g ((q q) (acc acc))
                (cond ((null? q) (cons q (if emit? (emw--rprepend acc out) out)))
                      ((char=? (car q) #\>)
                       (cons (cdr q) (if emit? (emw--rprepend (cons #\> acc) out) out)))
                      (else (g (cdr q) (cons (car q) acc))))))
             ((and (pair? nc) (pair? q) (char=? (char-downcase (car q)) (car nc)))
              (m (cdr q) (cdr nc) (cons (car q) acc)))
             (else (loop (cdr p) (if emit? (cons #\< out) out))))))
        (else (loop (cdr p) (if emit? (cons (car p) out) out)))))))

;; The block walker. mode 'kill → html minus every balanced matching block;
;; mode 'keep → the concatenated inner content of matching blocks, or #f.
(define (emw--walk-blocks html match? mode)
  (let ((keep? (equal? mode 'keep)))
    (let loop ((cs (string->list html))
               (out '())
               (skip #f)
               (ckpt #f)
               (matched #f))
      (if (null? cs)
          (cond
            ((and skip (not keep?) ckpt) (loop (car ckpt) (cdr ckpt) #f #f matched))
            (keep? (if matched (list->string (reverse out)) #f))
            (else (list->string (reverse out))))
          (let ((emit? (if skip (nth skip 2) (not keep?)))
                (c (car cs)))
            (if (not (char=? c #\<))
                (loop (cdr cs) (if emit? (cons c out) out) skip ckpt matched)
                (let* ((tk (emw--read-tag cs))
                       (kind (nth tk 0)) (name (nth tk 1)) (attrs (nth tk 2))
                       (selfc (nth tk 3)) (raw (nth tk 4)) (rest (nth tk 5)))
                  (cond
                    ((equal? kind 'text)
                     (loop (cdr cs) (if emit? (cons c out) out) skip ckpt matched))
                    ((equal? kind 'skip)
                     (loop rest out skip ckpt matched))
                    ((equal? kind 'close)
                     (if (and skip (equal? name (nth skip 0)))
                         (let ((d (- (nth skip 1) 1)))
                           (if (<= d 0)
                               (loop rest (if (and keep? emit?) (cons #\newline out) out)
                                     #f #f matched)
                               (loop rest (if emit? (emw--rprepend raw out) out)
                                     (list name d emit?) ckpt matched)))
                         (loop rest (if emit? (emw--rprepend raw out) out) skip ckpt matched)))
                    (skip
                     (let ((out2 (if emit? (emw--rprepend raw out) out))
                           (sk (if (and (equal? name (nth skip 0)) (not selfc))
                                   (list name (+ (nth skip 1) 1) emit?)
                                   skip)))
                       (if (and (member name emw--raw-tags) (not selfc))
                           (let ((r (emw--scan-raw rest name emit? out2)))
                             (loop (car r) (cdr r) sk ckpt matched))
                           (loop rest out2 sk ckpt matched))))
                    ((match? name attrs)
                     (cond
                       (selfc (loop rest out skip ckpt matched))
                       ((member name emw--raw-tags)
                        (let ((r (emw--scan-raw rest name #f out)))
                          (loop (car r) (cdr r) skip ckpt matched)))
                       (keep? (loop rest out (list name 1 #t) ckpt #t))
                       (else  (loop rest out (list name 1 #f) (cons rest out) matched))))
                    (else
                     (let ((out2 (if emit? (emw--rprepend raw out) out)))
                       (if (and (member name emw--raw-tags) (not selfc))
                           (let ((r (emw--scan-raw rest name emit? out2)))
                             (loop (car r) (cdr r) skip ckpt matched))
                           (loop rest out2 skip ckpt matched))))))))))))

;; Chrome classification (Readability-style junk lists).
(define emw--kill-tags
  (list "script" "style" "noscript" "template" "svg" "iframe" "form" "button"
        "select" "datalist" "nav" "header" "footer" "aside" "head" "object"
        "embed" "video" "audio" "canvas" "dialog" "menu" "map"))
(define emw--junk-block-tags
  (list "div" "section" "ul" "ol" "table" "span" "p" "a" "li" "td" "tr"
        "figure" "details" "dd" "dt"))
(define emw--junk-substrings
  (list "sidebar" "side-bar" "related" "recommend" "newsletter" "subscribe"
        "advert" "sponsor" "promo" "social" "share" "cookie" "consent" "gdpr"
        "popup" "modal" "overlay" "breadcrumb" "masthead" "skyscraper"
        "taboola" "outbrain" "disqus" "paywall" "dropdown" "offcanvas"
        "skip-link" "sr-only" "screen-reader" "visually-hidden"))
(define emw--junk-tokens
  (list "ad" "ads" "advertisement" "banner" "nav" "navs" "hidden"
        "hide" "menu"))
(define emw--junk-roles
  (list "navigation" "banner" "complementary" "contentinfo" "dialog"
        "alertdialog" "menu" "menubar" "toolbar" "search" "tooltip"))

(define (emw--kill? tag attrs)
  (or (and (member tag emw--kill-tags) #t)
      (and (not (member tag (list "html" "body")))
           (or (equal? (em--aget attrs "aria-hidden") "true")
               (and (em--aget attrs "hidden") #t)
               (let ((r (em--aget attrs "role")))
                 (and r (member r emw--junk-roles) #t))
               (let ((st (em--aget attrs "style")))
                 (and st
                      (let ((flat (list->string
                                   (filter (lambda (c) (not (char-whitespace? c)))
                                           (string->list st)))))
                        (or (string-contains? flat "display:none")
                            (string-contains? flat "visibility:hidden")))))
               (and (member tag emw--junk-block-tags)
                    (let ((cv (string-append (or (em--aget attrs "class") "") " "
                                             (or (em--aget attrs "id") ""))))
                      (and (> (string-length cv) 1)
                           (or (emw--any? (lambda (j) (string-contains? cv j))
                                          emw--junk-substrings)
                               (emw--any? (lambda (t) (and (member t emw--junk-tokens) #t))
                                          (filter (lambda (t) (not (equal? t "")))
                                                  (em--split-char cv #\space)))))))))))

(define (emw--article-tag? tag attrs)
  (or (equal? tag "article") (equal? (em--aget attrs "role") "article")))
(define (emw--main-tag? tag attrs)
  (or (equal? tag "main") (equal? (em--aget attrs "role") "main")))
(define emw--content-markers
  (list "post-content" "entry-content" "article-body" "articlebody"
        "article-content" "article__body" "article__content" "post-body"
        "post__content" "postcontent" "story-body" "story-content"
        "content-body" "main-content" "post-text" "blog-post"))
(define (emw--content-class? tag attrs)
  (and (member tag (list "div" "section" "td" "main"))
       (or (equal? (em--aget attrs "itemprop") "articlebody")
           (let ((cv (string-append (or (em--aget attrs "class") "") " "
                                    (or (em--aget attrs "id") ""))))
             (emw--any? (lambda (m) (string-contains? cv m)) emw--content-markers)))))

;; Reader-mode pass: strip chrome, then select the main content region; no
;; candidate (most HTML mail) → the whole cleaned message.
(define (emw--denoise html)
  (let* ((clean (emw--walk-blocks html emw--kill? 'kill))
         (lc (string-downcase clean))
         (try (lambda (present? pred)
                (and present?
                     (let ((c (emw--walk-blocks clean pred 'keep)))
                       (and c
                            (>= (string-length (em--trim (emw--strip-tags c))) 250)
                            c))))))
    (or (try (string-contains? lc "<article") emw--article-tag?)
        (try (or (string-contains? lc "<main")
                 (string-contains? lc "role=\"main\"")
                 (string-contains? lc "role='main'"))
             emw--main-tag?)
        (try (or (string-contains? lc "itemprop")
                 (emw--any? (lambda (m) (string-contains? lc m)) emw--content-markers))
             emw--content-class?)
        clean)))

;; Lift every <a href=…>text</a> into "text [N]", collecting the hrefs in
;; order (email hrefs are absolute — no base resolution needed).
(define (emw--extract-links html)
  (let* ((html (replace-regexp-in-string em--soh-str "" html))   ; paranoia
         (marked (replace-regexp-in-string
                  "(?is)<a\\b[^>]*?\\bhref\\s*=\\s*[\"']?([^\"'> ]+)[\"']?[^>]*>(.*?)</a>"
                  (string-append "$2" em--soh-str "$1" em--soh-str)
                  html))
         (pieces (em--split-char marked em--soh)))
    (let loop ((ps pieces) (i 0) (n 1) (urls '()) (out ""))
      (cond
        ((null? ps) (cons out (reverse urls)))
        ((= 0 (modulo i 2))
         (loop (cdr ps) (+ i 1) n urls (string-append out (car ps))))
        (else
         (loop (cdr ps) (+ i 1) (+ n 1)
               (cons (car ps) urls)
               (string-append out " [" (number->string n) "]")))))))

(define (emw--wrap line width)
  (let* ((line (em--trim line))
         (words (filter (lambda (w) (not (equal? w "")))
                        (em--split-char line #\space))))
    (if (null? words)
        (list "")
        (let loop ((ws (cdr words)) (cur (car words)) (acc '()))
          (cond
            ((null? ws) (reverse (cons cur acc)))
            ((<= (+ (string-length cur) 1 (string-length (car ws))) width)
             (loop (cdr ws) (string-append cur " " (car ws)) acc))
            (else (loop (cdr ws) (car ws) (cons cur acc))))))))

;; Structure is encoded as invisible control-char markers by a regex pass
;; (`emw--structure`), then a char-walk state machine (`emw--layout`) replays
;; them, maintaining indent/quote/pre depth. Markers use codes 14-28, which
;; never occur in real HTML (and `em--body-clean` scrubs any stray survivor).
(define EMW-PUSH   (integer->char 14))   ; list nesting deeper
(define EMW-POP    (integer->char 15))   ; …shallower
(define EMW-SETD0  (integer->char 16))   ; absolute-depth set, digits to SETD1
(define EMW-SETD1  (integer->char 17))
(define EMW-QON    (integer->char 18))   ; enter blockquote
(define EMW-QOFF   (integer->char 19))
(define EMW-PREON  (integer->char 20))   ; enter <pre> (preserve whitespace)
(define EMW-PREOFF (integer->char 21))
(define EMW-HEAD   (integer->char 22))   ; heading; next char is the level digit
(define EMW-BULL   (integer->char 23))   ; list-item line
(define EMW-BREAK  (integer->char 28))   ; hard line break
(define (emw--sc c) (list->string (list c)))

(define (emw--repeat s n) (let loop ((n n) (a "")) (if (<= n 0) a (loop (- n 1) (string-append a s)))))
(define (emw--spaces n) (emw--repeat " " n))
(define (emw--digit c) (let ((v (- (char->integer c) 48))) (if (and (>= v 0) (<= v 9)) v #f)))

;; Regex pass: rewrite structural tags into markers, drop other tags, decode
;; entities. Whitespace survives here so <pre> can preserve it.
(define (emw--structure s)
  (let* ((brk  (emw--sc EMW-BREAK))
         (para (string-append brk brk))
         (s (replace-regexp-in-string "(?is)<pre\\b[^>]*>" (string-append para (emw--sc EMW-PREON)) s))
         (s (replace-regexp-in-string "(?is)</pre>" (string-append (emw--sc EMW-PREOFF) para) s))
         (s (replace-regexp-in-string "(?i)<blockquote\\b[^>]*>" (string-append brk (emw--sc EMW-QON)) s))
         (s (replace-regexp-in-string "(?i)</blockquote>" (string-append (emw--sc EMW-QOFF) brk) s))
         (s (replace-regexp-in-string "(?i)<(ul|ol)\\b[^>]*>" (emw--sc EMW-PUSH) s))
         (s (replace-regexp-in-string "(?i)</(ul|ol)>" (emw--sc EMW-POP) s))
         (s (replace-regexp-in-string "(?i)<li\\b[^>]*>" (string-append brk (emw--sc EMW-BULL)) s))
         (s (replace-regexp-in-string "(?i)<h([1-6])\\b[^>]*>" (string-append para (emw--sc EMW-HEAD) "$1") s))
         (s (replace-regexp-in-string "(?i)</h[1-6]>" para s))
         (s (replace-regexp-in-string "(?i)<(br|hr)\\b[^>]*/?>" brk s))
         (s (replace-regexp-in-string
             "(?is)<img\\b[^>]*\\balt\\s*=\\s*\"([^\"]+)\"[^>]*>" " (image: $1) " s))
         (s (replace-regexp-in-string
             "(?is)<img\\b[^>]*\\balt\\s*=\\s*'([^']+)'[^>]*>" " (image: $1) " s))
         (s (replace-regexp-in-string "(?i)</p>" para s))
         (s (replace-regexp-in-string "(?i)</(td|th)>" "  " s))       ; keep a table row together
         (s (replace-regexp-in-string
             (string-append "(?i)</(div|section|article|tr|table|main|dd|dt|dl"
                            "|details|figure|figcaption|header|footer)>") brk s))
         (s (replace-regexp-in-string
             (string-append "(?i)<(p|div|section|article|tr|main|dd|dt|table"
                            "|details|header|footer|figure|figcaption)\\b[^>]*>") brk s))
         (s (emw--strip-tags s))
         (s (em--entities s)))
    s))

(define (emw--noise? t)
  (or (>= (string-match "^[-•·|*‹›«»–—_=~> \t]+$" t) 0)
      (>= (string-match "^\\[[0-9]+\\]$" t) 0)))

;; Turn one finished logical line into a list of text lines: indent/quote
;; prefix, bullet or heading marker, wrapped to the view width with a hanging
;; indent on continuations.
(define (emw--emit raw pre? heading qd indent hnbase bullet)
  (let* ((ind    (emw--spaces (* 2 (+ indent hnbase))))
         (bars   (emw--repeat "│ " qd))
         (prefix (string-append ind bars)))
    (if pre?
        (list (string-append prefix raw))
        (let ((t (em--trim raw)))
          (cond
            ((equal? t "")
             (if (and (= indent 0) (= qd 0) (= hnbase 0)) (list "") '()))
            ((and (= heading 0) (emw--noise? t)) '())
            (else
             (let* ((t2  (if (> heading 0) (string-append (emw--repeat "#" heading) " " t) t))
                    (t3  (if bullet (string-append "• " t2) t2))
                    (av  (let ((a (- *email-view-width* (string-length prefix)))) (if (< a 24) 24 a)))
                    (cpx (string-append ind bars (if bullet "  " ""))))
               (let w ((ws (emw--wrap t3 av)) (first? #t) (acc '()))
                 (if (null? ws)
                     (reverse acc)
                     (w (cdr ws) #f
                        (cons (string-append (if first? prefix cpx) (car ws)) acc)))))))))))

;; The char-walk state machine: consume the marker stream and return lines.
(define (emw--layout s)
  (define out '())
  (define cur '())
  (define indent 0) (define qd 0) (define pre #f) (define hnbase 0)
  (define heading 0) (define bullet #f) (define lastspace #t)
  (define (flush!)
    (let ((lines (emw--emit (list->string (reverse cur)) pre heading qd indent hnbase bullet)))
      (set! out (append (reverse lines) out))
      ;; A bullet whose line produced no text yet (<li><p>…) carries over to
      ;; the next flush, so block children of <li> keep their bullet.
      (set! bullet (if (and bullet (null? lines) (not pre)) #t #f))
      (set! cur '()) (set! heading 0) (set! lastspace #t)))
  (let loop ((cs (string->list s)))
    (if (null? cs)
        (begin (flush!) (reverse out))
        (let ((c (car cs)))
          (cond
            ((char=? c EMW-PUSH)   (flush!) (set! bullet #f) (set! indent (+ indent 1)) (loop (cdr cs)))
            ((char=? c EMW-POP)    (flush!) (set! bullet #f) (set! indent (if (> indent 0) (- indent 1) 0)) (loop (cdr cs)))
            ((char=? c EMW-QON)    (flush!) (set! bullet #f) (set! qd (+ qd 1)) (loop (cdr cs)))
            ((char=? c EMW-QOFF)   (flush!) (set! bullet #f) (set! qd (if (> qd 0) (- qd 1) 0)) (loop (cdr cs)))
            ((char=? c EMW-PREON)  (flush!) (set! pre #t) (loop (cdr cs)))
            ((char=? c EMW-PREOFF) (flush!) (set! pre #f) (loop (cdr cs)))
            ((char=? c EMW-BULL)   (set! bullet #t) (loop (cdr cs)))
            ((char=? c EMW-BREAK)  (flush!) (loop (cdr cs)))
            ((char=? c EMW-HEAD)
             (if (pair? (cdr cs))
                 (begin (set! heading (or (emw--digit (cadr cs)) 1)) (loop (cddr cs)))
                 (loop (cdr cs))))
            ((char=? c EMW-SETD0)
             (flush!)
             (let d ((ds (cdr cs)) (acc '()))
               (cond ((null? ds) (loop ds))
                     ((char=? (car ds) EMW-SETD1)
                      (set! hnbase (or (string->number (list->string (reverse acc))) 0))
                      (loop (cdr ds)))
                     (else (d (cdr ds) (cons (car ds) acc))))))
            (pre
             (if (char=? c #\newline)
                 (begin (flush!) (loop (cdr cs)))
                 (begin (set! cur (cons c cur)) (loop (cdr cs)))))
            ((char-whitespace? c)
             (when (and (not lastspace) (pair? cur)) (set! cur (cons #\space cur)))
             (set! lastspace #t)
             (loop (cdr cs)))
            (else (set! cur (cons c cur)) (set! lastspace #f) (loop (cdr cs))))))))

;; Collapse runs of blank lines to a single blank.
(define (emw--squeeze lines)
  (let loop ((ls lines) (prev-blank #t) (out '()))
    (if (null? ls)
        (reverse out)
        (let ((blank? (equal? (car ls) "")))
          (if (and blank? prev-blank)
              (loop (cdr ls) #t out)
              (loop (cdr ls) blank? (cons (car ls) out)))))))

;; Every "[N]" marker on `line` as (byte-col . number), left to right — the
;; hit-test data for following a link at point.
(define (emw--line-markers line)
  (let* ((m (replace-regexp-in-string "(\\[[0-9]+\\])"
                                      (string-append em--soh-str "$1" em--soh-str) line))
         (pieces (em--split-char m em--soh)))       ; text, "[N]", text, "[N]", …
    (let loop ((ps pieces) (i 0) (acc '()))
      (cond
        ((null? ps) (reverse acc))
        ((= 0 (modulo i 2)) (loop (cdr ps) (+ i 1) acc))
        (else
         (let* ((tok (car ps))                       ; e.g. "[12]"
                (bc  (string-match (regexp-quote tok) line))
                (n   (string->number (substring tok 1 (- (string-length tok) 1)))))
           (loop (cdr ps) (+ i 1)
                 (if (and (>= bc 0) n) (cons (cons bc n) acc) acc))))))))

;; Given a line's markers (sorted by column) and the cursor byte column, pick
;; the link at or after the column — the cursor on a link's text lands on its
;; trailing [N] — falling back to the last marker on the line.
(define (emw--pick-marker markers col)
  (let loop ((ms markers) (fallback (cdr (car markers))))
    (cond ((null? ms) fallback)
          ((>= (car (car ms)) col) (cdr (car ms)))
          (else (loop (cdr ms) (cdr (car ms)))))))

;; The HTML mail renderer: reader-mode extraction + structured layout, with
;; the numbered links appended as a footer, falling back to the regex
;; stripper if the engine trips on pathological input.
(define (em--html->text html)
  (with-handler
   (lambda (err) (em--html->text-basic html))
   (let* ((main (emw--denoise html))
          (lk (emw--extract-links main))
          (lines (emw--squeeze (emw--layout (emw--structure (car lk)))))
          (urls (cdr lk))
          (body (em--join lines "\n")))
     (em--body-clean
      (if (null? urls)
          body
          (string-append
           body "\n\nLinks:\n"
           (em--join (let loop ((us urls) (i 1) (acc '()))
                       (if (null? us)
                           (reverse acc)
                           (loop (cdr us) (+ i 1)
                                 (cons (string-append " [" (number->string i) "] " (car us))
                                       acc))))
                     "\n")))))))

;; ── RFC 822 / MIME parsing (raw messages, the IMAP path) ────────────────────
;; Header block → alist of (lowercased-name . folded-joined-value).
(define (em--parse-headers block)
  (let loop ((ls (em--split-char block #\newline)) (acc '()) (cur #f))
    (if (null? ls)
        (reverse (if cur (cons cur acc) acc))
        (let ((line (em--trim-crlf (car ls))))
          (cond
            ((equal? line "") (reverse (if cur (cons cur acc) acc)))
            ((and cur (em--matches? "^[ \t]" line))
             (loop (cdr ls) acc (cons (car cur) (string-append (cdr cur) " " (em--trim line)))))
            (else
             (let ((k (em--cap "^([!-9;-~]+):" line)))
               (if k
                   (loop (cdr ls) (if cur (cons cur acc) acc)
                         (cons (em--downcase k)
                               (em--trim (or (em--cap "^[!-9;-~]+:(.*)$" line) ""))))
                   (loop (cdr ls) acc cur)))))))))

(define (em--hdr headers name-lc)
  (let ((v (em--aget headers name-lc)))
    (if v v "")))

;; Split a raw message into (header-block . body-text) at the first blank line.
(define (em--split-raw raw)
  (let loop ((ls (em--split-char raw #\newline)) (head '()))
    (cond
      ((null? ls) (cons (em--join (reverse head) "\n") ""))
      ((equal? (em--trim-crlf (car ls)) "")
       (cons (em--join (reverse head) "\n") (em--join (cdr ls) "\n")))
      (else (loop (cdr ls) (cons (car ls) head))))))

;; Quoted-printable → hex ("=XX" = byte, "=\n" soft break vanishes).
(define (em--qp->hex s)
  (let ((s (replace-regexp-in-string "=\r?\n" "" s)))
    (let loop ((cs (string->list s)) (acc '()))
      (cond
        ((null? cs) (em--concat (reverse acc)))
        ((and (char=? (car cs) #\=) (pair? (cdr cs)) (pair? (cdr (cdr cs))))
         (loop (cdr (cdr (cdr cs)))
               (cons (em--hex2 (em--hexval (list->string (list (nth cs 1) (nth cs 2))))) acc)))
        (else (loop (cdr cs)
                    (cons (em--hex2 (let ((i (char->integer (car cs)))) (if (< i 256) i 63)))
                          acc)))))))

;; Decode one leaf part's raw text per its transfer encoding → hex bytes.
(define (em--cte->hex raw cte)
  (let ((c (em--downcase cte)))
    (cond
      ((em--matches? "base64" c) (base64url-hex raw))
      ((em--matches? "quoted-printable" c) (em--qp->hex raw))
      (else (em--latin1->hex raw)))))

;; Split a multipart body's LINES on its boundary → list of part strings.
;; A boundary delimiter line always begins with "--", so only those lines get
;; the (regex) trim + compare; the base64/text bulk — thousands of lines in a
;; message with a large attachment — skips it. Without this guard the per-line
;; trim ran two regexes on every line and dominated MIME parsing (seconds on a
;; ~1 MB message), which is what froze indexing.
(define (em--split-boundary body boundary)
  (let ((open (string-append "--" boundary))
        (close (string-append "--" boundary "--")))
    (let loop ((ls (em--split-char body #\newline)) (cur #f) (parts '()))
      (if (null? ls)
          (reverse (if cur (cons (em--join (reverse cur) "\n") parts) parts))
          (let* ((line (car ls))
                 (t (and (starts-with? line "--") (em--trim (em--trim-crlf line)))))
            (cond
              ((equal? t close)
               (reverse (if cur (cons (em--join (reverse cur) "\n") parts) parts)))
              ((equal? t open)
               (loop (cdr ls) '() (if cur (cons (em--join (reverse cur) "\n") parts) parts)))
              (cur (loop (cdr ls) (cons line cur) parts))
              (else (loop (cdr ls) #f parts))))))))   ; preamble

;; Flatten a raw message into leaf hashes ('headers 'raw 'section 'mime
;; 'charset 'cte 'filename), sections numbered IMAP-style ("1", "2.1", …).
(define (em--mime-leaves raw prefix)
  (let* ((sp (em--split-raw raw))
         (hs (em--parse-headers (car sp)))
         (body (cdr sp))
         (ctval (em--hdr hs "content-type"))
         (ct (em--downcase ctval)))
    (if (em--matches? "^multipart/" (em--trim ct))
        (let ((boundary (em--cap "(?i)boundary=\"?([^\";]+)" ctval)))
          (if (not boundary)
              '()
              (let loop ((ps (em--split-boundary body boundary)) (i 1) (acc '()))
                (if (null? ps)
                    acc
                    (loop (cdr ps) (+ i 1)
                          (append acc
                                  (em--mime-leaves
                                   (car ps)
                                   (if (equal? prefix "")
                                       (number->string i)
                                       (string-append prefix "." (number->string i))))))))))
        (list (hash 'headers hs
                    'raw body
                    'section (if (equal? prefix "") "1" prefix)
                    'mime (em--trim (let ((m (em--cap "^([^;]+)" ct))) (if m (em--trim m) "text/plain")))
                    'charset (em--charset-of ctval)
                    'cte (em--hdr hs "content-transfer-encoding")
                    ;; NB: not `fn` — that's Steel's lambda shorthand keyword.
                    'filename (let ((fname (or (em--cap "(?i)filename=\"?([^\";]+)" (em--hdr hs "content-disposition"))
                                               (em--cap "(?i)name=\"?([^\";]+)" ctval))))
                                (if fname (em--sanitize (em--decode-header fname)) "")))))))

(define (em--leaf-text leaf)
  (decode-charset (em--cte->hex (hash-try-get leaf 'raw) (hash-try-get leaf 'cte))
                  (hash-try-get leaf 'charset)))

;; True when a text/plain part shows visible character loss its text/html
;; sibling doesn't — the classic Outlook/Exchange case: a Windows-1252 plain
;; part downgrades an emoji to a literal "?" (or our own decode yields U+FFFD),
;; while the HTML alternative still carries it (e.g. `&#128522;`). We flip to
;; HTML only when a loss marker ("?" or U+FFFD) is present in the plain text AND
;; the HTML holds an emoji/pictograph codepoint that the plain text lacks. The
;; trigger ranges are deliberately narrow — emoji supplementary planes plus the
;; Misc-Symbols/Dingbats/stars block — and pointedly EXCLUDE General Punctuation
;; (curly quotes, dashes, ellipsis, bullets), arrows and geometric shapes, which
;; mailers routinely render straight in plain and typographic in HTML. So
;; ordinary plain mail (smart quotes, accents, a real "?") stays on the plain
;; part and its cleaner reader output. `plain`/`html` are the already rendered
;; texts (or #f when that alternative is absent).

;; Emoji / pictograph codepoint. Capped at U+1FAFF (end of Symbols & Pictographs
;; Extended-A) so astral non-emoji — CJK Ext-B at U+20000+, math alphanumerics —
;; aren't misread as emoji. `em--emoji-rx` is the SAME ranges as a regex, so the
;; two stay in lockstep; keep them together if you touch either.
(define (em--emoji-cp? cp)
  (or (and (>= cp #x1F000) (<= cp #x1FAFF))   ; emoji & pictographs (astral)
      (and (>= cp #x2600) (<= cp #x2BFF))))    ; misc symbols / dingbats / stars
(define em--emoji-rx "[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{2BFF}]")
(define em--ufffd (list->string (list (integer->char 65533))))  ; the � char

(define (em--plain-degraded? plain html)
  (and plain html
       ;; Two fast Rust-side gates first, so the overwhelmingly common case —
       ;; no loss marker, or no emoji in the HTML — returns without building any
       ;; per-char list. This runs once per message, including for EVERY message
       ;; during a local index rebuild, so the cheap path must stay cheap.
       (or (string-contains? plain "?")
           (string-contains? plain em--ufffd))
       (em--matches? em--emoji-rx html)
       ;; Rare path: the HTML has an emoji and the plain part shows a loss
       ;; marker. Flag as degraded unless the plain part actually carries that
       ;; same emoji (then nothing was lost). Build the plain codepoint set once.
       (let ((pset (let build ((cs (map char->integer (string->list plain))) (h (hash)))
                     (if (null? cs) h (build (cdr cs) (hash-insert h (car cs) #t))))))
         (let loop ((hs (string->list html)))
           (cond ((null? hs) #f)
                 ((let ((cp (char->integer (car hs))))
                    (and (em--emoji-cp? cp) (not (hash-try-get pset cp))))
                  #t)
                 (else (loop (cdr hs))))))))

;; Display body from MIME leaves: text/plain wins, text/html second — but a
;; text/plain part with visible charset loss yields to its HTML sibling.
(define (em--pick-body-mime leaves)
  (let ((plain (let loop ((ps leaves))
                 (cond ((null? ps) #f)
                       ((and (equal? (hash-try-get (car ps) 'mime) "text/plain")
                             (equal? (hash-try-get (car ps) 'filename) ""))
                        (em--body-clean (em--leaf-text (car ps))))
                       (else (loop (cdr ps))))))
        (html (let loop ((ps leaves))
                (cond ((null? ps) #f)
                      ((and (equal? (hash-try-get (car ps) 'mime) "text/html")
                            (equal? (hash-try-get (car ps) 'filename) ""))
                       (em--html->text (em--leaf-text (car ps))))
                      (else (loop (cdr ps)))))))
    (cond ((em--plain-degraded? plain html) html)
          (plain plain)
          (html html)
          (else "(no displayable body)"))))

;; Attachments from MIME leaves: (name mime approx-size section) per file.
(define (em--atts-mime leaves)
  (let loop ((ps leaves) (acc '()))
    (if (null? ps)
        (reverse acc)
        (let ((name (hash-try-get (car ps) 'filename)))
          (loop (cdr ps)
                (if (equal? name "")
                    acc
                    (cons (list name
                                (hash-try-get (car ps) 'mime)
                                (exact (round (* 0.75 (string-length (hash-try-get (car ps) 'raw)))))
                                (hash-try-get (car ps) 'section))
                          acc)))))))

;; ── REST payload parsing (the OAuth path: format=full JSON) ─────────────────
(define (em--header-value-json headers name-lc)
  (let loop ((hs headers))
    (cond ((null? hs) "")
          ((equal? (em--downcase (em--jstr (em--j (car hs) 'name))) name-lc)
           (em--jstr (em--j (car hs) 'value)))
          (else (loop (cdr hs))))))

(define (em--leaf-parts-json p)
  (let ((mt (or (em--j p 'mimeType) "")))
    (if (starts-with? mt "multipart")
        (let loop ((ps (em--as-list (em--j p 'parts))) (acc '()))
          (if (null? ps)
              acc
              (loop (cdr ps) (append acc (em--leaf-parts-json (car ps))))))
        (list p))))

(define (em--part-charset part)
  (em--charset-of (em--header-value-json (em--as-list (em--j part 'headers)) "content-type")))

(define (em--part-data part)
  (let ((data (em--jstr (em--j (em--j part 'body) 'data))))
    (if (equal? data "")
        #f
        (decode-charset (base64url-hex data) (em--part-charset part)))))

(define (em--pick-body-json leaves)
  (let ((plain (let loop ((ps leaves))
                 (cond ((null? ps) #f)
                       ((and (starts-with? (or (em--j (car ps) 'mimeType) "") "text/plain")
                             (equal? (em--jstr (em--j (car ps) 'filename)) "")
                             (em--part-data (car ps)))
                        (em--body-clean (em--part-data (car ps))))
                       (else (loop (cdr ps))))))
        (html (let loop ((ps leaves))
                (cond ((null? ps) #f)
                      ((and (starts-with? (or (em--j (car ps) 'mimeType) "") "text/html")
                            (equal? (em--jstr (em--j (car ps) 'filename)) "")
                            (em--part-data (car ps)))
                       (em--html->text (em--part-data (car ps))))
                      (else (loop (cdr ps)))))))
    (cond ((em--plain-degraded? plain html) html)
          (plain plain)
          (html html)
          (else "(no displayable body)"))))

;; Attachments from REST leaves: (name mime size attachmentId) per file.
(define (em--atts-json leaves)
  (let loop ((ps leaves) (acc '()))
    (if (null? ps)
        (reverse acc)
        (let ((name (em--decode-header (em--jstr (em--j (car ps) 'filename)))))
          (loop (cdr ps)
                (if (equal? name "")
                    acc
                    (cons (list (em--sanitize name)
                                (or (em--j (car ps) 'mimeType) "application/octet-stream")
                                (em--jint (em--j (em--j (car ps) 'body) 'size))
                                (em--jstr (em--j (em--j (car ps) 'body) 'attachmentId)))
                          acc)))))))

;; ── local store ─────────────────────────────────────────────────────────────
;; Shared by both backends. index line:
;;   id␟thread␟date␟from␟to␟subject␟labels,␟snippet␟msgid␟uid
;; header line: "macros-email-index 3"␟historyId␟uidvalidity␟maxuid␟me
;; — BOTH backends' sync baselines persist, so switching methods never loses
;; the other's incremental state. ids are hex X-GM-MSGID (= the REST id).
(define (em--entry-line e)
  (string-append
   (hash-try-get e 'id) em--us
   (hash-try-get e 'thread) em--us
   (number->string (hash-try-get e 'date)) em--us
   (hash-try-get e 'from) em--us
   (hash-try-get e 'to) em--us
   (hash-try-get e 'subject) em--us
   (em--join (hash-try-get e 'labels) ",") em--us
   (hash-try-get e 'snippet) em--us
   (hash-try-get e 'msgid) em--us
   (number->string (hash-try-get e 'uid))))

(define (em--save)
  (let loop ((ids (reverse (em--st 'ids)))
             (lines (list (string-append "macros-email-index 3" em--us
                                         (em--st 'history-id) em--us
                                         (em--st 'uid-validity) em--us
                                         (number->string (em--st 'max-uid)) em--us
                                         (em--st 'me)))))
    (if (null? ids)
        (write-file (em--index-file)
                    (string-append (em--join (reverse lines) "\n") "\n"))
        (let ((e (hash-try-get (em--st 'db) (car ids))))
          (loop (cdr ids) (if e (cons (em--entry-line e) lines) lines))))))

(define (em--load)
  (when (not (em--st 'loaded))
    (em--st! 'loaded #t)
    (when (file-exists? (em--index-file))
      (let ((lines (em--split-char (read-file (em--index-file)) #\newline)))
        (when (pair? lines)
          (let ((hdr (em--split-char (car lines) (integer->char 31))))
            (when (and (>= (length hdr) 5)
                       (starts-with? (nth hdr 0) "macros-email-index 3"))
              (em--st! 'history-id (nth hdr 1))
              (em--st! 'uid-validity (nth hdr 2))
              (em--st! 'max-uid (or (string->number (nth hdr 3)) 0))
              (em--st! 'me (nth hdr 4))))
          (let loop ((ls (cdr lines)))
            (when (pair? ls)
              (let ((f (em--split-char (car ls) (integer->char 31))))
                (when (= (length f) 10)
                  (let ((e (hash 'id (nth f 0)
                                 'thread (nth f 1)
                                 'date (or (string->number (nth f 2)) 0)
                                 'from (nth f 3)
                                 'to (nth f 4)
                                 'subject (nth f 5)
                                 'labels (filter (lambda (t) (not (equal? t "")))
                                                 (em--split-char (nth f 6) #\,))
                                 'snippet (nth f 7)
                                 'msgid (nth f 8)
                                 'uid (or (string->number (nth f 9)) 0))))
                    (when (not (hash-try-get (em--st 'db) (nth f 0)))
                      (em--st! 'ids (cons (nth f 0) (em--st 'ids))))
                    (em--st! 'db (hash-insert (em--st 'db) (nth f 0) e)))))
              (loop (cdr ls)))))))
    (em--pending-load)))

(define (em--db-remove id)
  (when (hash-try-get (em--st 'db) id)
    (em--st! 'ids (filter (lambda (x) (not (equal? x id))) (em--st 'ids)))
    (em--st! 'db (hash-insert (em--st 'db) id #f))))

;; Update one message's label set locally: `add`/`remove` are string lists.
(define (em--relabel id add remove)
  (let ((e (hash-try-get (em--st 'db) id)))
    (when e
      (let* ((labels (hash-try-get e 'labels))
             (labels (filter (lambda (l) (not (member l remove))) labels))
             (labels (let loop ((as add) (ls labels))
                       (cond ((null? as) ls)
                             ((member (car as) ls) (loop (cdr as) ls))
                             (else (loop (cdr as) (cons (car as) ls)))))))
        (em--st! 'db (hash-insert (em--st 'db) id (hash-insert e 'labels labels)))))))

;; ── pending flag ops (backend-neutral, persisted) ───────────────────────────
;; One "id␟kind" line per op; kinds: read unread star unstar archive trash.
;; Whichever backend runs the next sync replays them — by REST modify/trash
;; calls, or by IMAP STORE/MOVE located via X-GM-MSGID. Local labels update
;; immediately so the UI never waits.
(define (em--pending-save)
  (write-file (em--pending-file)
              (em--concat
               (map (lambda (op) (string-append (car op) em--us (cdr op) "\n"))
                    (em--st 'pending-ops)))))

(define (em--pending-load)
  (when (file-exists? (em--pending-file))
    (em--st! 'pending-ops
             (filter (lambda (x) x)
                     (map (lambda (line)
                            (let ((f (em--split-char line (integer->char 31))))
                              (if (= (length f) 2) (cons (nth f 0) (nth f 1)) #f)))
                          (filter (lambda (l) (not (equal? l "")))
                                  (em--split-char (read-file (em--pending-file)) #\newline)))))))

(define (em--queue-op id kind)
  (cond
    ((equal? kind "read")    (em--relabel id '() '("UNREAD")))
    ((equal? kind "unread")  (em--relabel id '("UNREAD") '()))
    ((equal? kind "star")    (em--relabel id '("STARRED") '()))
    ((equal? kind "unstar")  (em--relabel id '() '("STARRED")))
    ((equal? kind "archive") (em--relabel id '() '("INBOX")))
    ((equal? kind "trash")   (em--relabel id '("TRASH") '("INBOX"))))
  (em--st! 'pending-ops (append (em--st 'pending-ops) (list (cons id kind))))
  (em--pending-save)
  ;; The REST backend can flush immediately (async, nothing blocks); the IMAP
  ;; backend batches until the next sync.
  (when (em--oauth?)
    (em--run-op (lambda () (em--replay-ops-rest (lambda () (em--op-done)))))))

;; ── authinfo ────────────────────────────────────────────────────────────────
;; Emacs auth-source, translated: secrets live in a netrc-format file instead
;; of init.scm. Plaintext or GPG-encrypted — a path ending in .gpg is piped
;; through `gpg --decrypt` (gpg-agent/pinentry supplies the passphrase).
;;
;;   machine imap.gmail.com login work@corp.com password <app-password>
;;   machine me@gmail.com   login client-id     password <….googleusercontent.com>
;;   machine me@gmail.com   login client-secret password <GOCSPX-…>
;;
;; App passwords key on machine = the account's IMAP host, login = the account
;; name (mu4e's convention); OAuth client credentials key on machine = the
;; account name, login = the field. Lookup order per secret: the account hash
;; → the global "email-…" option → authinfo. Files searched: the account's
;; 'authinfo field, else the "email-authinfo" option, else ~/.authinfo.gpg,
;; ~/.authinfo, ~/.netrc — first match wins.

;; netrc tokens: whitespace-separated words; "double quotes" group a value
;; containing spaces; # at the start of a token comments to end of line.
;; One char-list pass (no byte/char index mixing).
(define (em--authinfo-tokenize s)
  (let loop ((cs (string->list s)) (cur '()) (toks '()) (q #f) (c #f))
    (let ((flushed (if (null? cur) toks (cons (list->string (reverse cur)) toks))))
      (cond
        ((null? cs) (reverse flushed))
        (c (loop (cdr cs) '() toks q (not (equal? (car cs) #\newline))))
        (q (if (equal? (car cs) #\")
               (loop (cdr cs) cur toks #f #f)
               (loop (cdr cs) (cons (car cs) cur) toks #t #f)))
        ((equal? (car cs) #\") (loop (cdr cs) cur toks #t #f))
        ((and (equal? (car cs) #\#) (null? cur)) (loop (cdr cs) '() toks #f #t))
        ((or (equal? (car cs) #\space) (equal? (car cs) #\tab)
             (equal? (car cs) #\newline) (equal? (car cs) #\return))
         (loop (cdr cs) '() flushed #f #f))
        (else (loop (cdr cs) (cons (car cs) cur) toks #f #f))))))

(define (em--authinfo-key t)
  (cond ((equal? t "login") 'login)
        ((equal? t "password") 'password)
        ((equal? t "port") 'port)
        (else #f)))

;; Token stream → list of {machine login password port} hashes. An entry
;; starts at "machine <name>" (or bare "default", which matches any machine).
(define (em--authinfo-entries text)
  (let loop ((ts (em--authinfo-tokenize text)) (cur #f) (out '()))
    (cond
      ((null? ts) (reverse (if cur (cons cur out) out)))
      ((equal? (car ts) "default")
       (loop (cdr ts) (hash 'machine "") (if cur (cons cur out) out)))
      ((and (equal? (car ts) "machine") (pair? (cdr ts)))
       (loop (cdr (cdr ts)) (hash 'machine (car (cdr ts))) (if cur (cons cur out) out)))
      ((not cur) (loop (cdr ts) #f out))
      ((and (pair? (cdr ts)) (em--authinfo-key (car ts)))
       (loop (cdr (cdr ts)) (hash-insert cur (em--authinfo-key (car ts)) (car (cdr ts))) out))
      (else (loop (cdr ts) cur out)))))

;; First password in TEXT whose machine and login match. A "default" entry
;; (machine "") matches any machine; a login of "" on either side is a
;; wildcard. Pure — the file/decrypt layer is separate, so this is testable.
(define (em--authinfo-find-in text machine login)
  (let loop ((es (em--authinfo-entries text)))
    (if (null? es) #f
        (let* ((e (car es))
               (m (em--jstr (em--j e 'machine)))
               (l (em--jstr (em--j e 'login)))
               (p (em--jstr (em--j e 'password))))
          (if (and (or (equal? m "") (equal? m machine))
                   (or (equal? login "") (equal? l "") (equal? l login))
                   (not (equal? p "")))
              p
              (loop (cdr es)))))))

(define (em--authinfo-files)
  (let ((v (em--trim (em--acct 'authinfo "email-authinfo" ""))))
    (if (equal? v "")
        (list "~/.authinfo.gpg" "~/.authinfo" "~/.netrc")
        (list v))))

;; GUI launches get the bare system PATH, so probe the usual gpg homes.
(define (em--gpg-bin)
  (let loop ((cs (list "/opt/homebrew/bin/gpg" "/usr/local/bin/gpg"
                       "/opt/local/bin/gpg" "/usr/bin/gpg")))
    (cond ((null? cs) "gpg")
          ((file-exists? (car cs)) (car cs))
          (else (loop (cdr cs))))))

(define (em--gpg-file? p)
  (let ((n (string-length p)))
    (and (> n 4) (equal? (substring p (- n 4) n) ".gpg"))))

;; Read (and decrypt) one authinfo file, caching the text per path for the
;; session — a pinentry prompt happens at most once, not on every lookup.
;; "" caches a missing/failed read; M-x email-reload-authinfo clears.
(define (em--authinfo-text path0)
  (let* ((path (em--expand-home path0))
         (cache (let ((c (em--st 'authinfo-cache))) (if (hash? c) c (hash))))
         (hit (hash-try-get cache path)))
    (cond
      ((string? hit) (if (equal? hit "") #f hit))
      ((not (file-exists? path))
       (em--st! 'authinfo-cache (hash-insert cache path ""))
       #f)
      (else
       (let ((text
              (if (em--gpg-file? path)
                  (let ((r (call-process-full (em--gpg-bin)
                                              (list "--quiet" "--batch" "--decrypt" path)
                                              "")))
                    (if (equal? (car r) "0")
                        (car (cdr r))
                        (begin (message (string-append "email: gpg failed to decrypt " path)) "")))
                  (read-file path))))
         (em--st! 'authinfo-cache (hash-insert cache path text))
         (if (equal? text "") #f text))))))

(define (em--authinfo-find machine login)
  (let loop ((fs (em--authinfo-files)))
    (if (null? fs) #f
        (or (let ((text (em--authinfo-text (car fs))))
              (and text (em--authinfo-find-in text machine login)))
            (loop (cdr fs))))))

;; Forget cached authinfo text (after editing the file mid-session).
(define (email-reload-authinfo)
  (em--st! 'authinfo-cache (hash))
  (message "email: authinfo cache cleared"))

;; ── keychain ────────────────────────────────────────────────────────────────
;; One keychain entry per account per credential kind, so mailboxes never
;; share or clobber each other's secrets.
(define (em--kc-token) (string-append "macros-email-refresh-token:" (em--account)))
(define (em--kc-pass)  (string-append "macros-email-app-password:" (em--account)))

(define (em--keychain-read service)
  (let ((r (call-process-full "security"
                              (list "find-generic-password" "-a" "macros-email"
                                    "-s" service "-w")
                              "")))
    (if (equal? (car r) "0") (em--trim (car (cdr r))) #f)))

(define (em--keychain-write service secret)
  (let ((r (call-process-full "security"
                              (list "add-generic-password" "-a" "macros-email"
                                    "-s" service "-w" secret "-U")
                              "")))
    (equal? (car r) "0")))

(define (em--refresh-token)
  (when (not (em--st 'token-loaded))
    (em--st! 'token-loaded #t)
    (let ((kc (em--keychain-read (em--kc-token))))
      (cond
        ((and kc (not (equal? kc ""))) (em--st! 'refresh-token kc))
        ((file-exists? (em--token-file))
         (let ((t (em--trim (read-file (em--token-file)))))
           (when (not (equal? t "")) (em--st! 'refresh-token t)))))))
  (em--st 'refresh-token))

(define (em--save-refresh-token token)
  (em--st! 'refresh-token token)
  (em--st! 'token-loaded #t)
  (when (not (em--keychain-write (em--kc-token) token))
    (write-file (em--token-file) token)
    (call-process-full "chmod" (list "600" (em--token-file)) "")))

(define (em--app-pass)
  (when (not (em--st 'pass-loaded))
    (em--st! 'pass-loaded #t)
    ;; authinfo first (declared config beats a cached prompt): mu4e-style
    ;; machine <imap-host> login <account>, or machine <account> login
    ;; app-password. Then the keychain / file the login prompt saved to.
    (let ((ai (or (em--authinfo-find (em--imap-host) (em--account))
                  (em--authinfo-find (em--account) "app-password"))))
      (if ai
          (em--st! 'app-pass ai)
          (let ((kc (em--keychain-read (em--kc-pass))))
            (cond
              ((and kc (not (equal? kc ""))) (em--st! 'app-pass kc))
              ((file-exists? (em--pass-file))
               (let ((t (em--trim (read-file (em--pass-file)))))
                 (when (not (equal? t "")) (em--st! 'app-pass t)))))))))
  (em--st 'app-pass))

(define (em--save-app-pass secret)
  (em--st! 'app-pass secret)
  (em--st! 'pass-loaded #t)
  (when (not (em--keychain-write (em--kc-pass) secret))
    (write-file (em--pass-file) secret)
    (call-process-full "chmod" (list "600" (em--pass-file)) "")))

;; Credentials exist for the ACTIVE method (used by the auto-sync guard).
(define (em--logged-in?)
  (if (em--oauth?)
      (if (em--refresh-token) #t #f)
      (and (em--app-pass) (not (equal? (em--st 'me) "")) #t)))

;; ── async http layer (the OAuth/REST transport) ─────────────────────────────
;; ONE request in flight; a single named dispatcher pops the stored
;; continuation. Multi-request flows are "ops" on a queue — an op owns the
;; connection until it calls `em--op-done` (exactly once, on every path).
(define (em--http method url headers body k)
  (em--st! 'http-k k)
  (http-request method url headers body 'email--http-response))

(define (em--split-status payload)
  (let loop ((cs (string->list payload)) (acc '()))
    (cond ((null? cs) (cons (list->string (reverse acc)) ""))
          ((char=? (car cs) #\newline)
           (cons (list->string (reverse acc)) (list->string (cdr cs))))
          (else (loop (cdr cs) (cons (car cs) acc))))))

(define (email--http-response payload)
  (let ((k (em--st 'http-k)))
    (em--st! 'http-k #f)
    (when k
      (let* ((sp (em--split-status payload))
             (status (or (string->number (em--trim (car sp))) 0)))
        (k status (cdr sp))))))

(define (em--run-op thunk)
  (if (em--st 'busy)
      (em--st! 'ops (append (em--st 'ops) (list thunk)))
      (begin (em--st! 'busy #t) (thunk))))

(define (em--op-done)
  (let ((ops (em--st 'ops)))
    (if (null? ops)
        (em--st! 'busy #f)
        (begin (em--st! 'ops (cdr ops)) ((car ops))))))

(define (em--2xx? status) (and (>= status 200) (< status 300)))

;; Run `k` with a live access token (refreshing first when expired), or #f.
(define (em--with-token k)
  (let ((tok (em--st 'access-token)))
    (if (and tok (> (em--st 'token-expiry) (+ (em--now) 30)))
        (k tok)
        (let ((rt (em--refresh-token)))
          (if (not rt)
              (begin (message "email: not logged in — press L (M-x email-login)") (k #f))
              (em--http "POST" "https://oauth2.googleapis.com/token"
                        (list "Content-Type" "application/x-www-form-urlencoded")
                        (em--form (append (list "client_id" (em--client-id)
                                                "grant_type" "refresh_token"
                                                "refresh_token" rt)
                                          (let ((sec (em--client-secret)))
                                            (if (equal? sec "") '() (list "client_secret" sec)))))
                        (lambda (status body)
                          (if (not (em--2xx? status))
                              (begin
                                (message (string-append "email: token refresh failed (HTTP "
                                                        (number->string status)
                                                        ") — M-x email-login"))
                                (k #f))
                              (let ((j (string->jsexpr body)))
                                (em--st! 'access-token (em--jstr (em--j j 'access_token)))
                                (em--st! 'token-expiry (+ (em--now) (em--jint (em--j j 'expires_in))))
                                (k (em--st 'access-token)))))))))))

;; Authenticated Gmail API request; one 401 retry via a forced refresh.
(define (em--api method path body k) (em--api-1 method path body k #t))
(define (em--api-1 method path body k retry?)
  (em--with-token
   (lambda (tok)
     (if (not tok)
         (k 0 "")
         (em--http method (string-append "https://gmail.googleapis.com" path)
                   (list "Authorization" (string-append "Bearer " tok)
                         "Accept" "application/json"
                         "Content-Type" "application/json")
                   body
                   (lambda (status resp)
                     (if (and (= status 401) retry?)
                         (begin (em--st! 'token-expiry 0)
                                (em--api-1 method path body k #f))
                         (k status resp))))))))

;; ── OAuth login (PKCE, loopback redirect) ───────────────────────────────────
(define em--login-page
  "<html><body style=\"font-family:sans-serif;margin:4em\"><h2>macros</h2><p>Login complete — you can close this tab and return to the editor.</p></body></html>")

(define (em--redirect-uri port)
  (string-append "http://127.0.0.1:" (number->string port)))

(define (em--login-oauth)
  (cond
    ((equal? (em--client-id) "")
     (message "email: set the \"email-client-id\" option first (see the README)"))
    ((em--st 'auth) (message "email: a login is already in progress"))
    (else
     (let* ((verifier (hex->base64url (random-bytes 32)))
            (challenge (hex->base64url (sha256 verifier)))
            (st8 (hex->base64url (random-bytes 16)))
            (port (http-serve "127.0.0.1" 0 "text/html" em--login-page
                              'email--oauth-callback)))
       (if (= port 0)
           (message "email: could not bind a loopback port")
           (begin
             (em--st! 'auth (hash 'verifier verifier 'state st8 'port port))
             (open-url
              (string-append
               "https://accounts.google.com/o/oauth2/v2/auth"
               "?client_id=" (em--urlenc (em--client-id))
               "&redirect_uri=" (em--urlenc (em--redirect-uri port))
               "&response_type=code"
               "&scope=" (em--urlenc "https://mail.google.com/")
               "&code_challenge=" challenge
               "&code_challenge_method=S256"
               "&state=" st8
               "&access_type=offline&prompt=consent"))
             (message "email: complete the login in your browser …")))))))

(define (email--oauth-callback target)
  (let ((auth (em--st 'auth)))
    (when auth
      (cond
        ((em--matches? "[?&]error=" target)
         (em--st! 'auth #f)
         (http-server-stop (hash-try-get auth 'port))
         (message (string-append "email: login refused — " (em--query-param target "error"))))
        ((em--matches? "[?&]code=" target)
         (let ((code (em--query-param target "code"))
               (st8 (em--query-param target "state"))
               (port (hash-try-get auth 'port))
               (verifier (hash-try-get auth 'verifier)))
           (when (equal? st8 (hash-try-get auth 'state))
             (em--st! 'auth #f)
             (http-server-stop port)
             (em--run-op
              (lambda ()
                (em--http "POST" "https://oauth2.googleapis.com/token"
                          (list "Content-Type" "application/x-www-form-urlencoded")
                          (em--form (append (list "code" code
                                                  "client_id" (em--client-id)
                                                  "redirect_uri" (em--redirect-uri port)
                                                  "grant_type" "authorization_code"
                                                  "code_verifier" verifier)
                                            (let ((sec (em--client-secret)))
                                              (if (equal? sec "") '() (list "client_secret" sec)))))
                          (lambda (status body)
                            (if (not (em--2xx? status))
                                (begin
                                  (message (string-append "email: token exchange failed (HTTP "
                                                          (number->string status) ")"))
                                  (em--op-done))
                                (let ((j (string->jsexpr body)))
                                  (em--st! 'access-token (em--jstr (em--j j 'access_token)))
                                  (em--st! 'token-expiry (+ (em--now) (em--jint (em--j j 'expires_in))))
                                  (let ((rt (em--jstr (em--j j 'refresh_token))))
                                    (when (not (equal? rt "")) (em--save-refresh-token rt)))
                                  (em--api "GET" "/gmail/v1/users/me/profile" ""
                                           (lambda (status body)
                                             (when (em--2xx? status)
                                               (em--st! 'me (em--jstr (em--j (string->jsexpr body) 'emailAddress))))
                                             (message (string-append "email: logged in as " (em--st 'me)
                                                                     " — syncing …"))
                                             (em--op-done)
                                             (email-sync))))))))))))
        (else #f)))))       ; favicon and friends — keep serving until the code arrives

;; ── IMAP client (blocking, the app-password transport) ──────────────────────
(define (em--imap-tag)
  (let ((n (+ 1 (em--st 'imap-tag))))
    (em--st! 'imap-tag n)
    (string-append "A" (number->string n))))

(define (em--imap-quote s)
  ;; Replacement backslashes are literal — "\\$1" is the correct escape.
  (string-append "\"" (replace-regexp-in-string "([\"\\\\])" "\\$1" s) "\""))

;; One logical response line: control text plus any {n}-literal payloads.
(define (em--imap-read-logical conn)
  (let loop ((ctrl "") (lits '()))
    (let ((line (tls-recv-line conn)))
      (if (equal? line "")
          (cons ctrl (reverse lits))
          (let* ((tl (em--trim-crlf line))
                 (n (let ((m (em--cap "\\{([0-9]+)\\}$" tl)))
                      (and m (string->number m)))))
            (if n
                (loop (string-append ctrl tl) (cons (tls-recv-bytes conn n) lits))
                (cons (string-append ctrl tl) (reverse lits))))))))

(define (em--imap-response conn tag)
  (let loop ((untagged '()))
    (let* ((pair (em--imap-read-logical conn))
           (ctrl (car pair)))
      (cond
        ((equal? ctrl "") (list (reverse untagged) ""))
        ((starts-with? ctrl (string-append tag " ")) (list (reverse untagged) ctrl))
        (else (loop (cons pair untagged)))))))

(define (em--imap-cmd conn cmd)
  (let ((tag (em--imap-tag)))
    (tls-send conn (string-append tag " " cmd "\r\n"))
    (let ((r (em--imap-response conn tag)))
      (list (car r) (car (cdr r))
            (starts-with? (car (cdr r)) (string-append tag " OK"))))))

(define (em--imap-ok? r) (nth r 2))

(define (em--imap-connect)
  (let ((user (em--st 'me))
        (pass (em--app-pass)))
    (cond
      ((or (equal? user "") (not pass))
       (message "email: not logged in — press L (M-x email-login)") #f)
      (else
       (let ((conn (tls-connect (em--imap-host) 993 0 0)))
         (if (= conn 0)
             (begin (message (string-append "email: connect failed — " (tls-last-error))) #f)
             (begin
               (em--imap-read-logical conn)     ; the greeting
               (if (em--imap-ok?
                    (em--imap-cmd conn (string-append "LOGIN " (em--imap-quote user)
                                                      " " (em--imap-quote pass))))
                   conn
                   (begin (tls-close conn)
                          (message "email: login refused — bad address or app password")
                          #f)))))))))

(define (em--imap-logout conn)
  (tls-send conn (string-append (em--imap-tag) " LOGOUT\r\n"))
  (tls-close conn))

(define (em--imap-select conn mailbox)
  (let ((r (em--imap-cmd conn (string-append "SELECT " (em--imap-quote mailbox)))))
    (if (not (em--imap-ok? r))
        #f
        (let loop ((ps (nth r 0)) (exists 0) (uv ""))
          (if (null? ps)
              (hash 'exists exists 'uidvalidity uv)
              (let* ((ctrl (car (car ps)))
                     (e (em--cap "^\\* ([0-9]+) EXISTS" ctrl))
                     (v (em--cap "UIDVALIDITY ([0-9]+)" ctrl)))
                (loop (cdr ps)
                      (if e (or (string->number e) exists) exists)
                      (if v v uv))))))))

(define (em--imap-search conn query)
  (let ((r (em--imap-cmd conn (string-append "UID SEARCH " query))))
    (if (not (em--imap-ok? r))
        '()
        (let loop ((ps (nth r 0)) (uids '()))
          (if (null? ps)
              (reverse uids)
              (let ((ctrl (car (car ps))))
                (if (starts-with? ctrl "* SEARCH")
                    (loop (cdr ps)
                          (append (reverse (filter (lambda (n) n)
                                                   (map string->number
                                                        (cdr (cdr (em--split-char ctrl #\space))))))
                                  uids))
                    (loop (cdr ps) uids))))))))

(define (em--imap-uid-of conn hex-id)
  (let ((uids (em--imap-search conn (string-append "X-GM-MSGID " (em--hex->dec hex-id)))))
    (if (null? uids) #f (car uids))))

;; ── IMAP envelope ingestion ─────────────────────────────────────────────────
(define em--fetch-items
  "(UID FLAGS X-GM-MSGID X-GM-THRID X-GM-LABELS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT MESSAGE-ID)])")

(define (em--parse-gm-labels s)
  (let loop ((toks (filter (lambda (t) (not (equal? t "")))
                           (em--split-char s #\space)))
             (acc '()))
    (if (null? toks)
        (reverse acc)
        (let* ((t (replace-regexp-in-string "^\"|\"$" "" (car toks)))
               ;; Quoted system labels arrive escaped ("\\Important").
               (t (replace-regexp-in-string "^\\\\+" "\\" t)))
          (loop (cdr toks)
                (cond ((equal? t "\\Inbox") (cons "INBOX" acc))
                      ((equal? t "\\Starred") (cons "STARRED" acc))
                      ((equal? t "\\Important") (cons "IMPORTANT" acc))
                      ((equal? t "\\Sent") (cons "SENT" acc))
                      ((equal? t "\\Draft") (cons "DRAFT" acc))
                      ((equal? t "\\Trash") (cons "TRASH" acc))
                      ((equal? t "\\Spam") (cons "SPAM" acc))
                      ((starts-with? t "\\") acc)
                      (else (cons t acc))))))))

;; Parse one "* n FETCH (…)" pair → envelope hash (hex-normalized ids), or #f.
(define (em--parse-fetch pair in-inbox?)
  (let* ((ctrl (car pair))
         (lits (cdr pair))
         (dec-id (em--cap "X-GM-MSGID ([0-9]+)" ctrl))
         (uid (em--cap "UID ([0-9]+)" ctrl)))
    (if (or (not dec-id) (not uid))
        #f
        (let* ((hs (em--parse-headers (if (null? lits) "" (car lits))))
               (flags (or (em--cap "FLAGS \\(([^)]*)\\)" ctrl) ""))
               (gml (em--parse-gm-labels (or (em--cap "X-GM-LABELS \\(([^)]*)\\)" ctrl) "")))
               (labels (append
                        (if (and in-inbox? (not (member "INBOX" gml))) '("INBOX") '())
                        (if (em--matches? "\\\\Seen" flags) '() '("UNREAD"))
                        (if (em--matches? "\\\\Flagged" flags) '("STARRED") '())
                        (filter (lambda (l) (not (member l '("UNREAD" "STARRED")))) gml))))
          (hash 'id (em--dec->hex dec-id)
                'uid (or (string->number uid) 0)
                'thread (em--dec->hex (or (em--cap "X-GM-THRID ([0-9]+)" ctrl) ""))
                'date (em--parse-internaldate (or (em--cap "INTERNALDATE \"([^\"]+)\"" ctrl) ""))
                'from (em--sanitize (em--decode-header (em--hdr hs "from")))
                'to (em--sanitize (em--decode-header (em--hdr hs "to")))
                'subject (em--sanitize (em--decode-header (em--hdr hs "subject")))
                'labels labels
                'snippet ""
                'msgid (em--sanitize (em--hdr hs "message-id")))))))

(define (em--fetch-envelopes conn cmd in-inbox?)
  (let ((r (em--imap-cmd conn cmd)))
    (if (not (em--imap-ok? r))
        '()
        (filter (lambda (x) x)
                (map (lambda (p) (em--parse-fetch p in-inbox?))
                     (filter (lambda (p) (em--matches? " FETCH " (car p))) (nth r 0)))))))

;; Merge one envelope into the db (new ids count toward 'new-count).
(define (em--db-merge e)
  (let* ((id (hash-try-get e 'id))
         (known (hash-try-get (em--st 'db) id)))
    (when (not known)
      (em--st! 'ids (cons id (em--st 'ids)))
      (em--st! 'new-count (+ 1 (em--st 'new-count))))
    ;; Keep a REST-era snippet if the IMAP refetch has none.
    (let ((e (if (and known (equal? (hash-try-get e 'snippet) ""))
                 (hash-insert e 'snippet (hash-try-get known 'snippet))
                 e)))
      (em--st! 'db (hash-insert (em--st 'db) id e)))))

;; ── REST envelope ingestion ─────────────────────────────────────────────────
(define em--meta-fields
  "?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Message-Id")

(define (em--db-add-meta j)
  (let* ((id (em--jstr (em--j j 'id)))
         (hs (em--as-list (em--j (em--j j 'payload) 'headers))))
    (when (not (equal? id ""))
      (em--db-merge
       (hash 'id id
             'uid (let ((known (hash-try-get (em--st 'db) id)))
                    (if known (hash-try-get known 'uid) 0))
             'thread (em--jstr (em--j j 'threadId))
             'date (quotient (or (string->number (em--jstr (em--j j 'internalDate))) 0) 1000)
             'from (em--sanitize (em--decode-header (em--header-value-json hs "from")))
             'to (em--sanitize (em--decode-header (em--header-value-json hs "to")))
             'subject (em--sanitize (em--decode-header (em--header-value-json hs "subject")))
             'labels (map em--jstr (em--as-list (em--j j 'labelIds)))
             'snippet (em--sanitize (em--entities (em--jstr (em--j j 'snippet))))
             'msgid (em--sanitize (em--header-value-json hs "message-id")))))))

(define (em--fetch-meta-loop k)
  (let ((q (em--st 'fetchq)))
    (if (null? q)
        (k)
        (begin
          (em--st! 'fetchq (cdr q))
          (em--api "GET"
                   (string-append "/gmail/v1/users/me/messages/" (car q) em--meta-fields)
                   ""
                   (lambda (status body)
                     (when (em--2xx? status)
                       (em--db-add-meta (string->jsexpr body)))
                     (em--fetch-meta-loop k)))))))

;; ── sync: dispatch ──────────────────────────────────────────────────────────
(define (email-sync)
  (em--load)
  (cond
    ((em--st 'syncing) (message "email: a sync is already running"))
    ((em--oauth?) (em--sync-rest))
    (else (em--sync-imap))))

;; ── sync: REST (async op chain) ─────────────────────────────────────────────
(define (em--sync-rest)
  (em--st! 'syncing #t)
  (em--st! 'new-count 0)
  (em--run-op
   (lambda ()
     (em--replay-ops-rest
      (lambda ()
        (let ((h (em--st 'history-id)))
          (if (equal? h "") (em--sync-rest-full) (em--sync-rest-history h))))))))

(define (em--sync-fail status)
  (em--st! 'syncing #f)
  (message (string-append "email: sync failed (HTTP " (number->string status) ")"))
  (em--op-done))

(define (em--sync-rest-finish)
  (em--st! 'syncing #f)
  (em--save)
  (when (equal? (current-buffer) "*email*")
    (em--list-render 'keep))
  (message (string-append "email: sync done — "
                          (number->string (em--st 'new-count)) " new"))
  ;; Queue the maildir mirror (if configured), the outbox flush, and the
  ;; offline body cache BEFORE releasing this op, so they run immediately
  ;; after — new arrivals land on disk and queued sends go out with the sync.
  ;; Flush before cache: sends are small and user-visible, the cache can run
  ;; long.
  (em--auto-export)
  (em--op-done)
  (em--outbox-autoflush)
  (em--cache-bodies))

;; Replay pending (id . kind) ops over REST: modify for flags, the trash
;; endpoint for trash. Transport failure keeps the queue; 4xx drops the op.
(define (em--op->rest op)             ; → (path . body)
  (let ((id (car op)) (kind (cdr op)))
    (define (mod add remove)
      (cons (string-append "/gmail/v1/users/me/messages/" id "/modify")
            (string-append "{\"addLabelIds\":[" add "],\"removeLabelIds\":[" remove "]}")))
    (cond
      ((equal? kind "read")    (mod "" "\"UNREAD\""))
      ((equal? kind "unread")  (mod "\"UNREAD\"" ""))
      ((equal? kind "star")    (mod "\"STARRED\"" ""))
      ((equal? kind "unstar")  (mod "" "\"STARRED\""))
      ((equal? kind "archive") (mod "" "\"INBOX\""))
      (else (cons (string-append "/gmail/v1/users/me/messages/" id "/trash") "{}")))))

(define (em--replay-ops-rest k)
  (let ((ops (em--st 'pending-ops)))
    (if (null? ops)
        (k)
        (let ((req (em--op->rest (car ops))))
          (em--api "POST" (car req) (cdr req)
                   (lambda (status body)
                     (cond
                       ((= status 0) (k))       ; offline — keep the queue
                       (else
                        (em--st! 'pending-ops (cdr (em--st 'pending-ops)))
                        (em--pending-save)
                        (em--replay-ops-rest k)))))))))

(define (em--sync-rest-full)
  (em--api "GET"
           (string-append "/gmail/v1/users/me/messages?maxResults="
                          (number->string (em--fetch-count))
                          "&q=" (em--urlenc (em--query)))
           ""
           (lambda (status body)
             (if (not (em--2xx? status))
                 (em--sync-fail status)
                 (let* ((j (string->jsexpr body))
                        (ids (map (lambda (m) (em--jstr (em--j m 'id)))
                                  (em--as-list (em--j j 'messages)))))
                   (em--st! 'fetchq
                            (filter (lambda (id) (not (hash-try-get (em--st 'db) id))) ids))
                   (em--fetch-meta-loop
                    (lambda ()
                      (em--api "GET" "/gmail/v1/users/me/profile" ""
                               (lambda (status body)
                                 (when (em--2xx? status)
                                   (let ((j (string->jsexpr body)))
                                     (em--st! 'history-id (em--jstr (em--j j 'historyId)))
                                     (em--st! 'me (em--jstr (em--j j 'emailAddress)))))
                                 (em--sync-rest-finish))))))))))

(define (em--sync-rest-history baseline)
  (em--rest-history-page baseline "" baseline))

(define (em--rest-history-page baseline page-token newest)
  (em--api "GET"
           (string-append "/gmail/v1/users/me/history?startHistoryId=" baseline
                          "&maxResults=500"
                          (if (equal? page-token "") ""
                              (string-append "&pageToken=" (em--urlenc page-token))))
           ""
           (lambda (status body)
             (cond
               ((= status 404)
                (em--st! 'history-id "")
                (em--sync-rest-full))
               ((not (em--2xx? status)) (em--sync-fail status))
               (else
                (let* ((j (string->jsexpr body))
                       (newest (let ((h (em--jstr (em--j j 'historyId))))
                                 (if (equal? h "") newest h)))
                       (next (em--jstr (em--j j 'nextPageToken))))
                  (for-each em--apply-rest-history (em--as-list (em--j j 'history)))
                  (if (equal? next "")
                      (begin
                        (em--st! 'history-id newest)
                        (em--fetch-meta-loop (lambda () (em--sync-rest-finish))))
                      (em--rest-history-page baseline next newest))))))))

(define (em--apply-rest-history h)
  (for-each
   (lambda (rec)
     (let* ((m (em--j rec 'message))
            (id (em--jstr (em--j m 'id)))
            (labels (map em--jstr (em--as-list (em--j m 'labelIds)))))
       (when (and (not (equal? id ""))
                  (not (member "SPAM" labels))
                  (not (member "TRASH" labels))
                  (not (hash-try-get (em--st 'db) id))
                  (not (member id (em--st 'fetchq))))
         (em--st! 'fetchq (cons id (em--st 'fetchq))))))
   (em--as-list (em--j h 'messagesAdded)))
  (for-each
   (lambda (rec)
     (em--db-remove (em--jstr (em--j (em--j rec 'message) 'id))))
   (em--as-list (em--j h 'messagesDeleted)))
  (for-each
   (lambda (rec)
     (em--relabel (em--jstr (em--j (em--j rec 'message) 'id))
                  (map em--jstr (em--as-list (em--j rec 'labelIds))) '()))
   (em--as-list (em--j h 'labelsAdded)))
  (for-each
   (lambda (rec)
     (em--relabel (em--jstr (em--j (em--j rec 'message) 'id))
                  '() (map em--jstr (em--as-list (em--j rec 'labelIds)))))
   (em--as-list (em--j h 'labelsRemoved))))

;; ── sync: IMAP (one blocking conversation) ──────────────────────────────────
(define (em--sync-imap)
  (em--st! 'syncing #t)
  (em--st! 'new-count 0)
  (message "email: syncing …")
  (let ((conn (em--imap-connect)))
    (if (not conn)
        (em--st! 'syncing #f)
        (begin
          (em--replay-ops-imap conn)
          (let ((sel (em--imap-select conn "INBOX")))
            (cond
              ((not sel) (message "email: SELECT INBOX failed"))
              (else
               (when (not (equal? (hash-try-get sel 'uidvalidity) (em--st 'uid-validity)))
                 (em--st! 'uid-validity (hash-try-get sel 'uidvalidity))
                 (em--st! 'max-uid 0))
               (if (= (em--st 'max-uid) 0)
                   (em--sync-imap-full conn sel)
                   (em--sync-imap-incremental conn))
               (em--save))))
          (em--imap-logout conn)
          (em--st! 'syncing #f)
          (when (equal? (current-buffer) "*email*")
            (em--list-render 'keep))
          (message (string-append "email: sync done — "
                                  (number->string (em--st 'new-count)) " new"))
          (em--auto-export)
          (em--outbox-autoflush)
          (em--cache-bodies)))))

(define (em--sync-imap-full conn sel)
  (let* ((exists (hash-try-get sel 'exists))
         (n (em--fetch-count)))
    (when (> exists 0)
      (let* ((lo (if (> exists n) (+ 1 (- exists n)) 1))
             (range (string-append (number->string lo) ":" (number->string exists)))
             (envs (em--fetch-envelopes conn (string-append "FETCH " range " " em--fetch-items) #t)))
        (for-each em--db-merge envs)
        (for-each (lambda (e)
                    (let ((u (hash-try-get e 'uid)))
                      (when (> u (em--st 'max-uid)) (em--st! 'max-uid u))))
                  envs)))))

(define (em--sync-imap-incremental conn)
  (let* ((maxuid (em--st 'max-uid))
         (news (em--fetch-envelopes
                conn
                (string-append "UID FETCH " (number->string (+ maxuid 1)) ":* " em--fetch-items)
                #t))
         (news (filter (lambda (e) (> (hash-try-get e 'uid) maxuid)) news)))
    (for-each em--db-merge news)
    (for-each (lambda (e)
                (let ((u (hash-try-get e 'uid)))
                  (when (> u (em--st 'max-uid)) (em--st! 'max-uid u))))
              news)
    ;; Refresh flags of the tracked INBOX messages; the missing were expunged.
    (let* ((tracked (filter (lambda (id)
                              (let ((e (hash-try-get (em--st 'db) id)))
                                (and e (member "INBOX" (hash-try-get e 'labels))
                                     (> (hash-try-get e 'uid) 0)
                                     (<= (hash-try-get e 'uid) maxuid))))
                            (em--st 'ids)))
           (uids (map (lambda (id) (hash-try-get (hash-try-get (em--st 'db) id) 'uid)) tracked)))
      (when (pair? uids)
        (let* ((uidset (em--join (map number->string uids) ","))
               (envs (em--fetch-envelopes
                      conn
                      (string-append "UID FETCH " uidset " " em--fetch-items) #t))
               (present (map (lambda (e) (hash-try-get e 'id)) envs)))
          (for-each em--db-merge envs)
          (for-each (lambda (id)
                      (when (not (member id present))
                        (em--relabel id '() '("INBOX"))))
                    tracked))))))

;; Replay pending ops via IMAP against All Mail (X-GM-MSGID locates each
;; message regardless of mailbox). Best-effort: failures drop the op.
(define (em--replay-ops-imap conn)
  (let ((ops (em--st 'pending-ops)))
    (when (pair? ops)
      (when (em--imap-select conn em--all-mail)
        (for-each
         (lambda (op)
           (let ((uid (em--imap-uid-of conn (car op)))
                 (kind (cdr op)))
             (when uid
               (let ((u (number->string uid)))
                 (cond
                   ((equal? kind "read")
                    (em--imap-cmd conn (string-append "UID STORE " u " +FLAGS (\\Seen)")))
                   ((equal? kind "unread")
                    (em--imap-cmd conn (string-append "UID STORE " u " -FLAGS (\\Seen)")))
                   ((equal? kind "star")
                    (em--imap-cmd conn (string-append "UID STORE " u " +FLAGS (\\Flagged)")))
                   ((equal? kind "unstar")
                    (em--imap-cmd conn (string-append "UID STORE " u " -FLAGS (\\Flagged)")))
                   ((equal? kind "archive")
                    (em--imap-cmd conn (string-append "UID STORE " u " -X-GM-LABELS (\\Inbox)")))
                   ((equal? kind "trash")
                    (em--imap-cmd conn (string-append "UID MOVE " u " "
                                                      (em--imap-quote em--trash-box)))))))))
         ops)
        (em--st! 'pending-ops '())
        (em--pending-save)))))

;; ── message body fetch + normalized store (dispatch) ────────────────────────
;; Both backends write the same normalized file: decoded headers, blank line,
;; body text, then one RS-prefixed manifest line per attachment —
;; name␟mime␟size␟ref␟scheme, where scheme is "rest" (ref = attachmentId) or
;; "imap" (ref = MIME section), so a cache written under one method can be
;; detected and refreshed by the other.
(define (em--write-msg-file id head body atts scheme)
  (write-file (em--msg-file id)
              (string-append
               (em--join head "\n") "\n\n"
               body
               (em--concat
                (map (lambda (a)
                       (string-append "\n" em--rs (nth a 0) em--us (nth a 1) em--us
                                      (number->string (nth a 2)) em--us (nth a 3)
                                      em--us scheme))
                     atts)))))

(define (em--head-lines from to cc date-str subject)
  (let* ((head (list (string-append "From: " from)
                     (string-append "To: " to)))
         (head (if (equal? cc "") head
                   (append head (list (string-append "Cc: " cc))))))
    (append head (list (string-append "Date: " date-str)
                       (string-append "Subject: " subject)))))

(define (em--store-message-rest id j)
  (let* ((hs (em--as-list (em--j (em--j j 'payload) 'headers)))
         (leaves (em--leaf-parts-json (em--j j 'payload))))
    (em--write-msg-file
     id
     (em--head-lines
      (em--sanitize (em--decode-header (em--header-value-json hs "from")))
      (em--sanitize (em--decode-header (em--header-value-json hs "to")))
      (em--sanitize (em--decode-header (em--header-value-json hs "cc")))
      (em--date16 (quotient (or (string->number (em--jstr (em--j j 'internalDate))) 0) 1000))
      (em--sanitize (em--decode-header (em--header-value-json hs "subject"))))
     (em--pick-body-json leaves)
     (em--atts-json leaves)
     "rest")))

(define (em--store-message-imap id raw)
  (let* ((sp (em--split-raw raw))
         (hs (em--parse-headers (car sp)))
         (leaves (em--mime-leaves raw ""))
         (e (hash-try-get (em--st 'db) id)))
    (em--write-msg-file
     id
     (em--head-lines
      (em--sanitize (em--decode-header (em--hdr hs "from")))
      (em--sanitize (em--decode-header (em--hdr hs "to")))
      (em--sanitize (em--decode-header (em--hdr hs "cc")))
      (em--date16 (if e (hash-try-get e 'date) 0))
      (em--sanitize (em--decode-header (em--hdr hs "subject"))))
     (em--pick-body-mime leaves)
     (em--atts-mime leaves)
     "imap")))

;; Fetch + store one message via the active backend; `k` gets #t/#f.
(define (em--fetch-message id k)
  (if (em--oauth?)
      (em--run-op
       (lambda ()
         (message "email: fetching message …")
         (em--api "GET" (string-append "/gmail/v1/users/me/messages/" id "?format=full") ""
                  (lambda (status body)
                    (if (not (em--2xx? status))
                        (k #f)
                        (begin
                          (em--store-message-rest id (string->jsexpr body))
                          (k #t)))
                    (em--op-done)))))
      (begin
        (message "email: fetching message …")
        (let ((conn (em--imap-connect)))
          (if (not conn)
              (k #f)
              (let ((ok
                     (and (em--imap-select conn em--all-mail)
                          (let ((uid (em--imap-uid-of conn id)))
                            (and uid
                                 (let* ((r (em--imap-cmd conn (string-append
                                                               "UID FETCH " (number->string uid)
                                                               " (BODY.PEEK[])")))
                                        (fetch (filter (lambda (p)
                                                         (and (em--matches? " FETCH " (car p))
                                                              (pair? (cdr p))))
                                                       (nth r 0))))
                                   (and (em--imap-ok? r) (pair? fetch)
                                        (begin
                                          (em--store-message-imap id (car (cdr (car fetch))))
                                          #t))))))))
                (em--imap-logout conn)
                (k ok)))))))

;; ── list buffer ─────────────────────────────────────────────────────────────
(define em--list-help
  "  ? menu · enter open · C compose · R/E reply/all · A archive · D trash · U unread · * star · f folders · i inbox · s// search · a account · g/G refresh/sync · L login · q quit")

(define em--hidden-labels
  '("INBOX" "UNREAD" "STARRED" "IMPORTANT" "SENT" "DRAFT"
    "CATEGORY_PERSONAL" "CATEGORY_SOCIAL" "CATEGORY_PROMOTIONS"
    "CATEGORY_UPDATES" "CATEGORY_FORUMS"))

(define (em--labels-suffix labels)
  (let ((shown (filter (lambda (l) (not (member l em--hidden-labels))) labels)))
    (if (null? shown) "" (string-append "(" (em--downcase (em--join shown ",")) ")"))))

(define (em--visible-ids)
  (let ((db (em--st 'db))
        (sids (em--st 'search-ids)))
    (sort-by (lambda (id) (hash-try-get (hash-try-get db id) 'date)) >
             (if sids
                 (filter (lambda (id) (hash-try-get db id)) sids)
                 (filter (lambda (id)
                           (let ((e (hash-try-get db id)))
                             (and e
                                  (member "INBOX" (hash-try-get e 'labels))
                                  (not (member "TRASH" (hash-try-get e 'labels))))))
                         (em--st 'ids))))))

(define (em--ensure-faces) (set-face-bold "email-unread" #t))

(define (em--from-name from)
  (let ((name (em--cap "^\\s*\"?([^\"<]+?)\"?\\s*<" from)))
    (cond (name (em--trim name))
          ((em--matches? "^<.*>$" (em--trim from))
           (let ((t (em--trim from))) (substring t 1 (- (string-length t) 1))))
          (else (em--trim from)))))

(define (em--address-of s)
  (let ((a (em--cap "<([^>]+)>" s)))
    (if a a (em--trim s))))

;; Render *email*. `where` — 'top, 'keep, or a line number (feeds semantics).
(define (em--list-render where)
  (let* ((prev-line (buffer-line))
         (ids (em--visible-ids))
         (db (em--st 'db))
         (header (string-append "Email — " (number->string (length ids)) " messages"
                                (if (pair? (cdr (em--accounts)))
                                    (string-append " — [" (em--account) "]")
                                    "")
                                (let ((me (em--st 'me)))
                                  (if (equal? me "") "" (string-append " — " me)))
                                (string-append " — "
                                               (if (em--oauth?) "oauth" "app-password"))
                                (if (em--offline?) " — OFFLINE" "")
                                (let ((f (em--st 'folder)))
                                  (if f
                                      (string-append " — " f " (f folders · i inbox)")
                                      ""))
                                (let ((ops (length (em--st 'pending-ops))))
                                  (if (> ops 0)
                                      (string-append " — " (number->string ops) " flag-ops")
                                      ""))
                                (let ((ob (em--outbox-count)))
                                  (if (> ob 0)
                                      (string-append " — " (number->string ob) " outbox")
                                      ""))
                                (if (em--st 'syncing) " — syncing…" "")))
         (already? (equal? (current-buffer) "*email*")))
    (em--st! 'view ids)
    (let loop ((rest ids) (idx 3)
               (abs (+ (em--bytelen header) 1 (em--bytelen em--list-help) 1 1))
               (texts (list "" em--list-help header))
               (faces (list (list 0 "keyword") (list 1 "comment")))
               (ospans '()))
      (if (null? rest)
          (begin
            (em--ensure-faces)
            ((if already? render-buffer-quiet render-buffer)
             "*email*" "email-list-mode"
             (em--join (reverse texts) "\n") (reverse faces))
            (clear-overlays)
            (overlay-set-faces (reverse ospans))
            (goto-line (cond ((and (equal? where 'keep) already? (>= prev-line 3)) prev-line)
                             ((number? where) where)
                             (else 3))))
          (let* ((e (hash-try-get db (car rest)))
                 (labels (hash-try-get e 'labels))
                 (unread? (member "UNREAD" labels))
                 (datef (em--date16 (hash-try-get e 'date)))          ; 16 ASCII bytes
                 (starf (if (member "STARRED" labels) "* " "  "))     ; 2 ASCII bytes
                 (fromf (em--fit (em--from-name (hash-try-get e 'from)) *email-from-width*))
                 (subjf (em--truncate (hash-try-get e 'subject) *email-subject-width*))
                 (tagsf (em--labels-suffix labels))
                 (line (string-append datef "  " starf fromf "  " subjf
                                      (if (equal? tagsf "") "" "  ") tagsf))
                 (faces (cons (list idx (if unread? "email-unread" "comment")) faces))
                 (from-start (+ abs 16 2 2))
                 (from-end (+ from-start (em--bytelen fromf)))
                 (ospans (cons (list abs (+ abs 16) "comment")
                               (cons (list from-start from-end "function") ospans)))
                 (ospans (if (equal? tagsf "")
                             ospans
                             (let ((tstart (+ from-end 2 (em--bytelen subjf) 2)))
                               (cons (list tstart (+ tstart (em--bytelen tagsf)) "keyword")
                                     ospans)))))
            (loop (cdr rest) (+ idx 1) (+ abs (em--bytelen line) 1)
                  (cons line texts) faces ospans))))))

(define (em--id-at-point)
  (let* ((line (buffer-line))
         (idx (- line (em--st 'view-offset)))
         (view (em--st 'view)))
    (if (and (>= idx 0) (< idx (length view)))
        (nth view idx)
        #f)))

;; ── view buffer ─────────────────────────────────────────────────────────────
(define em--view-help
  "  ? menu · enter follow link · n/p next/prev · R/E reply/all · A archive · D trash · W save attachment · b gmail · q back")

;; Read the normalized store file → (head-lines body-lines attachments).
(define (em--read-message id)
  (let ((path (em--msg-file id)))
    (if (not (file-exists? path))
        #f
        (let loop ((ls (em--split-char (read-file path) #\newline))
                   (head '()) (body '()) (atts '()) (in-body #f))
          (if (null? ls)
              (list (reverse head) (reverse body) (reverse atts))
              (let ((line (car ls)))
                (cond
                  ((and (> (string-length line) 0)
                        (char=? (car (string->list line)) em--rs-ch))
                   (loop (cdr ls) head body
                         (cons (em--split-char (substring line 1 (string-length line))
                                               (integer->char 31))
                               atts)
                         in-body))
                  ((and (not in-body) (equal? line ""))
                   (loop (cdr ls) head body atts #t))
                  (in-body (loop (cdr ls) head (cons line body) atts #t))
                  (else (loop (cdr ls) (cons line head) body atts #f)))))))))

(define (em--view-render id)
  (let ((msg (em--read-message id)))
    (when msg
      (em--st! 'current id)
      (em--st! 'view-atts (nth msg 2))
      (let* ((head (nth msg 0))
             (atts (nth msg 2))
             (att-lines (let loop ((as atts) (i 1) (acc '()))
                          (if (null? as)
                              (reverse acc)
                              (loop (cdr as) (+ i 1)
                                    (cons (string-append "Attachment " (number->string i)
                                                         ": " (nth (car as) 0)
                                                         " (" (em--size-string (string->number (nth (car as) 2))) ")")
                                          acc)))))
             (body (let loop ((ls (nth msg 1)) (acc '()))
                     (if (null? ls)
                         (reverse acc)
                         (let w ((ws (em--wrap-line (car ls) *email-view-width*)) (acc acc))
                           (if (null? ws)
                               (loop (cdr ls) acc)
                               (w (cdr ws) (cons (car ws) acc)))))))
             (all (append head att-lines (list em--view-help "") body))
             (faces (let loop ((ls head) (i 0) (acc '()))
                      (if (null? ls)
                          (append (reverse acc)
                                  (let att ((n (length att-lines)) (i i) (acc2 '()))
                                    (if (= n 0)
                                        (reverse (cons (list i "comment") acc2))
                                        (att (- n 1) (+ i 1) (cons (list i "string") acc2)))))
                          (loop (cdr ls) (+ i 1)
                                (cons (list i (cond ((starts-with? (car ls) "Subject:") "keyword")
                                                    ((starts-with? (car ls) "From:") "function")
                                                    (else "comment")))
                                      acc)))))
             ;; The (number . url) map from the link footer, for enter/click.
             (links (let loop ((ls (nth msg 1)) (acc '()))
                      (if (null? ls)
                          (reverse acc)
                          (loop (cdr ls)
                                (let ((c (regexp-captures "^ \\[([0-9]+)\\] (.+)$" (car ls))))
                                  (if (null? c)
                                      acc
                                      (cons (cons (string->number (nth c 1)) (nth c 2)) acc)))))))
             ;; Absolute byte spans of every [N] marker, painted as links.
             (ospans (let walk ((ls all) (abs 0) (acc '()))
                       (if (null? ls)
                           (reverse acc)
                           (walk (cdr ls) (+ abs (em--bytelen (car ls)) 1)
                                 (let a ((ms (emw--line-markers (car ls))) (acc acc))
                                   (if (null? ms)
                                       acc
                                       (let* ((bc (car (car ms)))
                                              (n (cdr (car ms)))
                                              (s (+ abs bc))
                                              (e (+ s 2 (string-length (number->string n)))))
                                         (a (cdr ms) (cons (list s e "keyword") acc))))))))))
        (em--st! 'view-lines all)
        (em--st! 'view-links links)
        (render-buffer "*email-view*" "email-view-mode"
                       (em--join all "\n") faces)
        (clear-overlays)
        (overlay-set-faces ospans)
        (goto-line 0)))))

;; Open a message: cached file when present, else fetch via the active backend.
;; Opening always clears UNREAD (locally at once, replayed to the server).
(define (em--open id)
  (let ((e (hash-try-get (em--st 'db) id)))
    (when e
      (when (member "UNREAD" (hash-try-get e 'labels))
        (em--queue-op id "read"))
      (cond
        ((file-exists? (em--msg-file id)) (em--view-render id))
        ;; Offline: never reach for the network on open — show local only.
        ((em--offline?)
         (message "email: not downloaded — G to sync (offline mode caches new mail)"))
        (else
         (em--fetch-message
          id
          (lambda (ok)
            (if ok
                (em--view-render id)
                (message "email: could not fetch the message")))))))))

;; ── compose + send ──────────────────────────────────────────────────────────
(define em--separator "--text follows this line--")

(define (em--compose to cc subject body in-reply-to thread-id)
  (kill-buffer-named "*email-compose*")
  (append-to-buffer "*email-compose*"
                    (string-append "To: " to "\nCc: " cc "\nSubject: " subject "\n"
                                   em--separator "\n" body))
  (set-major-mode "email-compose-mode")
  (buffer-local-set "email-in-reply-to" in-reply-to)
  (buffer-local-set "email-thread-id" thread-id)
  (goto-char 4)
  (message "email: compose — C-c C-c send · C-c C-k discard · C-c C-a attach · C-c C-b bcc · M-i complete address"))

(define (email-compose) (em--compose "" "" "" "" "" ""))

;; The value of the head line starting with `prefix` ("To: " …), or "".
(define (em--head-value head prefix)
  (let loop ((ls head))
    (cond ((null? ls) "")
          ((starts-with? (car ls) prefix)
           (substring (car ls) (string-length prefix) (string-length (car ls))))
          (else (loop (cdr ls))))))

;; The Cc list for a reply-all: every recipient of the original (its To + Cc
;; fields, comma-separated header values) except the addresses in `exclude`
;; (ours, and the reply's To target) — deduped case-insensitively.
(define (em--reply-all-cc to-field cc-field exclude)
  (let loop ((vals (append (em--split-char to-field #\,)
                           (em--split-char cc-field #\,)))
             (seen '()) (out '()))
    (if (null? vals)
        (em--join (reverse out) ", ")
        (let ((a (em--address-of (car vals))))
          (if (or (equal? a "")
                  (not (em--matches? "@" a))
                  (member (em--downcase a) exclude)
                  (member (em--downcase a) seen))
              (loop (cdr vals) seen out)
              (loop (cdr vals) (cons (em--downcase a) seen) (cons a out)))))))

;; Reply (`all?` = reply-all). Reply-all recipients come from the cached
;; message file's decoded To/Cc head lines when the message has been opened;
;; from the db envelope's To otherwise (the envelope doesn't carry Cc).
(define (em--reply id all?)
  (let ((e (hash-try-get (em--st 'db) id)))
    (when e
      (let* ((subject (hash-try-get e 'subject))
             (subject (if (em--matches? "(?i)^re:" subject)
                          subject
                          (string-append "Re: " subject)))
             (msg (em--read-message id))
             (quoted (if msg
                         (string-append
                          "\n\nOn " (em--date16 (hash-try-get e 'date)) ", "
                          (em--from-name (hash-try-get e 'from)) " wrote:\n"
                          (em--join (map (lambda (l) (string-append "> " l)) (nth msg 1)) "\n"))
                         ""))
             (to (em--address-of (hash-try-get e 'from)))
             (cc (if (not all?)
                     ""
                     (em--reply-all-cc
                      (if msg (em--head-value (nth msg 0) "To: ") (hash-try-get e 'to))
                      (if msg (em--head-value (nth msg 0) "Cc: ") "")
                      (list (em--downcase to)
                            (em--downcase (em--st 'me)))))))
        (em--compose to cc subject quoted
                     (hash-try-get e 'msgid) (hash-try-get e 'thread))))))

;; Parse the compose buffer → hash, or #f when the separator is missing.
(define (em--parse-compose text)
  (let loop ((ls (em--split-char text #\newline))
             (to "") (cc "") (bcc "") (subject "") (attach '()))
    (cond
      ((null? ls) #f)
      ((equal? (car ls) em--separator)
       (hash 'to to 'cc cc 'bcc bcc 'subject subject 'attach (reverse attach)
             'body (em--join (cdr ls) "\n")))
      (else
       (let* ((line (car ls))
              (key (em--downcase (or (em--cap "^([A-Za-z-]+):" line) "")))
              (val (em--trim (or (em--cap "^[A-Za-z-]+:(.*)$" line) ""))))
         (cond
           ((equal? key "to") (loop (cdr ls) val cc bcc subject attach))
           ((equal? key "cc") (loop (cdr ls) to val bcc subject attach))
           ((equal? key "bcc") (loop (cdr ls) to cc val subject attach))
           ((equal? key "subject") (loop (cdr ls) to cc bcc val attach))
           ((equal? key "attach")
            (loop (cdr ls) to cc bcc subject (cons (em--expand-home val) attach)))
           (else (loop (cdr ls) to cc bcc subject attach))))))))

;; Assemble the RFC 822 message. `include-bcc?`: the REST path keeps the Bcc
;; header (Gmail reads it for delivery and strips it); the SMTP path must NOT
;; write it — bcc recipients ride the envelope only. Returns the raw string,
;; or #f after messaging about an unreadable attachment.
(define (em--mime-message p in-reply-to include-bcc?)
  (let* ((from (let ((addr (let ((a (em--acct 'address "email-address" "")))
                                 (if (equal? a "") (em--jstr (em--st 'me)) a)))
                     (name (em--acct 'from-name "email-name" "")))
                 (cond ((equal? addr "") #f)
                       ((equal? name "") (string-append "From: " addr))
                       (else (string-append "From: " (em--header-word name) " <" addr ">")))))
         (heads (append
                 (if from (list from) '())
                 (list (string-append "To: " (hash-try-get p 'to)))
                 (if (equal? (hash-try-get p 'cc) "") '()
                     (list (string-append "Cc: " (hash-try-get p 'cc))))
                 (if (or (not include-bcc?) (equal? (hash-try-get p 'bcc) "")) '()
                     (list (string-append "Bcc: " (hash-try-get p 'bcc))))
                 (list (string-append "Subject: " (em--header-word (hash-try-get p 'subject)))
                       (string-append "Date: " (current-time "%a, %d %b %Y %H:%M:%S %z"))
                       "MIME-Version: 1.0")
                 (if (equal? in-reply-to "") '()
                     (list (string-append "In-Reply-To: " in-reply-to)
                           (string-append "References: " in-reply-to)))))
         (atts (hash-try-get p 'attach))
         (body64 (em--b64std-of-string (hash-try-get p 'body))))
    (if (null? atts)
        (string-append
         (em--join heads "\r\n") "\r\n"
         "Content-Type: text/plain; charset=UTF-8\r\n"
         "Content-Transfer-Encoding: base64\r\n\r\n"
         body64 "\r\n")
        (let ((boundary (string-append "macros" (random-bytes 12))))
          (let loop ((as atts) (parts '()))
            (cond
              ((null? as)
               (string-append
                (em--join heads "\r\n") "\r\n"
                "Content-Type: multipart/mixed; boundary=\"" boundary "\"\r\n\r\n"
                "--" boundary "\r\n"
                "Content-Type: text/plain; charset=UTF-8\r\n"
                "Content-Transfer-Encoding: base64\r\n\r\n"
                body64 "\r\n"
                (em--concat (reverse parts))
                "--" boundary "--\r\n"))
              (else
               (let ((hexdata (read-file-hex (car as))))
                 (if (equal? hexdata "")
                     (begin
                       (message (string-append "email: cannot read attachment " (car as)))
                       #f)
                     (loop (cdr as)
                           (cons (string-append
                                  "--" boundary "\r\n"
                                  "Content-Type: application/octet-stream; name=\""
                                  (basename (car as)) "\"\r\n"
                                  "Content-Disposition: attachment; filename=\""
                                  (basename (car as)) "\"\r\n"
                                  "Content-Transfer-Encoding: base64\r\n\r\n"
                                  (em--b64std-of-hex hexdata) "\r\n")
                                 parts)))))))))))

;; ── SMTP client (blocking, implicit TLS 465 — the app-password send path) ───
(define (em--smtp-final? line)
  (and (>= (string-length line) 4) (equal? (substring line 3 4) " ")))

(define (em--smtp-reply conn)
  (let loop ((acc '()))
    (let ((line (tls-recv-line conn)))
      (if (equal? line "")
          (cons 0 (em--join (reverse acc) " "))
          (let ((tl (em--trim-crlf line)))
            (if (em--smtp-final? tl)
                (cons (or (string->number (substring tl 0 3)) 0)
                      (em--join (reverse (cons tl acc)) " "))
                (loop (cons tl acc))))))))

(define (em--smtp-cmd conn s)
  (tls-send conn (string-append s "\r\n"))
  (em--smtp-reply conn))

(define (em--smtp-dotstuff data)
  (let ((stuffed (replace-regexp-in-string "\r\n\\." "\r\n.." data)))
    (if (ends-with? stuffed "\r\n") stuffed (string-append stuffed "\r\n"))))

(define (em--smtp-send recipients raw)
  (let ((conn (tls-connect (em--smtp-host) 465 0 0)))
    (if (= conn 0)
        (begin (message (string-append "email: SMTP connect failed — " (tls-last-error))) #f)
        (let ((ok
               (and (= (car (em--smtp-reply conn)) 220)
                    (= (car (em--smtp-cmd conn "EHLO macros")) 250)
                    (let ((r1 (em--smtp-cmd conn "AUTH LOGIN")))
                      (and (= (car r1) 334)
                           (= (car (em--smtp-cmd conn (em--b64 (em--st 'me)))) 334)
                           (= (car (em--smtp-cmd conn (em--b64 (em--app-pass)))) 235)))
                    (= (car (em--smtp-cmd conn (string-append "MAIL FROM:<" (em--st 'me) ">"))) 250)
                    (let loop ((rs recipients) (ok #t))
                      (if (null? rs)
                          ok
                          (loop (cdr rs)
                                (and (= (car (em--smtp-cmd conn (string-append "RCPT TO:<" (car rs) ">"))) 250)
                                     ok))))
                    (= (car (em--smtp-cmd conn "DATA")) 354)
                    (begin (tls-send conn (em--smtp-dotstuff raw))
                           (= (car (em--smtp-cmd conn ".")) 250)))))
          (em--smtp-cmd conn "QUIT")
          (tls-close conn)
          ok))))

(define (em--recipients p)
  (filter (lambda (a) (not (equal? a "")))
          (map em--address-of
               (append (em--split-char (hash-try-get p 'to) #\,)
                       (em--split-char (hash-try-get p 'cc) #\,)
                       (em--split-char (hash-try-get p 'bcc) #\,)))))

(define (email-compose-send)
  (let ((p (em--parse-compose (buffer-string))))
    (cond
      ((not p) (message "email: separator line missing — is this a compose buffer?"))
      ((equal? (em--trim (hash-try-get p 'to)) "") (message "email: To is empty"))
      ;; Offline mode: don't attempt the network — queue for a later flush.
      ((em--offline?)
       (when (em--queue-to-outbox)
         (message (string-append "email: queued to the outbox ("
                                 (number->string (em--outbox-count))
                                 " pending) — email-outbox-flush to send"))))
      ((em--oauth?)
       (let ((raw (em--mime-message p (buffer-local-get "email-in-reply-to") #t))
             (thread (buffer-local-get "email-thread-id")))
         (when raw
           (em--run-op
            (lambda ()
              (message "email: sending …")
              (em--api "POST" "/gmail/v1/users/me/messages/send"
                       (string-append "{\"raw\":\"" (base64url-encode raw) "\""
                                      (if (equal? thread "") ""
                                          (string-append ",\"threadId\":\"" thread "\""))
                                      "}")
                       (lambda (status body)
                         (cond
                           ((em--2xx? status)
                            (kill-buffer-named "*email-compose*")
                            (message "email: sent"))
                           ;; Transport failure (0) → keep the text: queue it
                           ;; rather than lose it to a dropped connection.
                           ((= status 0)
                            (if (em--queue-to-outbox)
                                (message "email: offline — queued to the outbox")
                                (message "email: send failed and could not queue")))
                           (else
                            (message (string-append "email: send failed (HTTP "
                                                    (number->string status) ")"))))
                         (em--op-done))))))))
      ((not (em--app-pass)) (message "email: not logged in — M-x email-login"))
      (else
       (let ((raw (em--mime-message p (buffer-local-get "email-in-reply-to") #f)))
         (when raw
           (message "email: sending …")
           (if (em--smtp-send (em--recipients p) raw)
               (begin (kill-buffer-named "*email-compose*")
                      (message "email: sent"))
               ;; SMTP failed (likely offline) — queue instead of losing it.
               (if (em--queue-to-outbox)
                   (message "email: send failed — queued to the outbox")
                   (message "email: send failed")))))))))

(define (email-compose-cancel)
  (kill-buffer-named "*email-compose*")
  (message "email: compose discarded"))

;; Send later — queue into the outbox even in live mode, to send on the next
;; `email-outbox-flush`. Same path offline send uses.
(define (email-compose-send-later)
  (let ((p (em--parse-compose (buffer-string))))
    (cond
      ((not p) (message "email: separator line missing — is this a compose buffer?"))
      ((equal? (em--trim (hash-try-get p 'to)) "") (message "email: To is empty"))
      (else
       (when (em--queue-to-outbox)
         (message (string-append "email: queued to the outbox ("
                                 (number->string (em--outbox-count))
                                 " pending) — email-outbox-flush to send")))))))

;; ── compose helpers: attach, Bcc, address completion ────────────────────────
;; Byte offset of the start of the first line satisfying `pred` in the current
;; buffer, or #f — for inserting header lines into the compose buffer.
(define (em--compose-line-offset pred)
  (let loop ((ls (em--split-char (buffer-string) #\newline)) (abs 0))
    (cond ((null? ls) #f)
          ((pred (car ls)) abs)
          (else (loop (cdr ls) (+ abs (em--bytelen (car ls)) 1))))))

;; C-c C-a — pick a file and add an `Attach:` header line above the separator.
(define (email-compose-attach)
  (read-file-name "Attach file: " 'email--compose-attach-cb))
(define (email--compose-attach-cb path)
  (let ((path (em--trim path)))
    (when (not (equal? path ""))
      (let ((off (em--compose-line-offset (lambda (l) (equal? l em--separator)))))
        (if (not off)
            (message "email: separator line missing — is this a compose buffer?")
            (begin
              (goto-char off)
              (insert (string-append "Attach: " path "\n"))
              (message (string-append "email: will attach " path))))))))

;; C-c C-b — add a Bcc header (cursor lands right after it), once.
(define (email-compose-toggle-bcc)
  (if (em--compose-line-offset (lambda (l) (em--matches? "^[Bb]cc:" l)))
      (message "email: Bcc header already present")
      (let ((off (em--compose-line-offset (lambda (l) (equal? l em--separator)))))
        (if (not off)
            (message "email: separator line missing — is this a compose buffer?")
            (begin
              (goto-char off)
              (insert "Bcc: \n")
              (goto-char (+ off 5)))))))

;; Every address seen in the account's envelopes (from + to fields), newest
;; first, deduped — the autocomplete source for To/Cc/Bcc.
(define (em--address-book)
  (let loop ((ids (em--st 'ids)) (seen '()) (out '()))
    (if (null? ids)
        (reverse out)
        (let ((e (hash-try-get (em--st 'db) (car ids))))
          (if (not e)
              (loop (cdr ids) seen out)
              (let add ((vals (append (em--split-char (hash-try-get e 'from) #\,)
                                      (em--split-char (hash-try-get e 'to) #\,)))
                        (seen seen) (out out))
                (if (null? vals)
                    (loop (cdr ids) seen out)
                    (let ((a (em--downcase (em--address-of (car vals)))))
                      (if (or (equal? a "")
                              (not (em--matches? "@" a))
                              (em--matches? "[<> ]" a)
                              (member a seen))
                          (add (cdr vals) seen out)
                          (add (cdr vals) (cons a seen) (cons a out)))))))))))

;; CAPF: complete addresses on the To/Cc/Bcc lines of *email-compose* (M-i,
;; and the automatic completion chain). Declines everywhere else. Returns an
;; explicit (start end cands) range so the whole address token — dots, @,
;; hyphens — is replaced, not just the last word.
(define (email-address-capf prefix)
  (if (not (equal? (current-buffer) "*email-compose*"))
      '()
      (let* ((p (point))
             (lb (line-bounds))
             (line (buffer-substring (car lb) p)))    ; the line, up to point
        (if (not (em--matches? "^(To|to|Cc|cc|Bcc|bcc):" line))
            '()
            (let* ((tok (let ((c (regexp-captures "[:,]\\s*([^,:]*)$" line)))
                          (if (null? c) "" (em--trim (nth c 1)))))
                   (start (- p (em--bytelen tok)))
                   (cands (filter (lambda (a) (and (starts-with? a (em--downcase tok))
                                                   (not (equal? a (em--downcase tok)))))
                                  (em--address-book))))
              (if (or (equal? tok "") (null? cands))
                  '()
                  (list start p cands)))))))
(add-completion-at-point-function "email-address-capf")

;; ── attachments (dispatch, with cross-backend cache refresh) ────────────────
;; The manifest carries which backend wrote it ("rest" attachmentId vs "imap"
;; MIME section). If the active backend can't use the stored ref, the message
;; is refetched through the active backend first — same id, same attachment
;; index — then saved from the fresh manifest.
(define (em--save-attachment-now id att path k)
  (if (em--oauth?)
      (em--run-op
       (lambda ()
         (message "email: downloading …")
         (em--api "GET"
                  (string-append "/gmail/v1/users/me/messages/" id
                                 "/attachments/" (nth att 3))
                  ""
                  (lambda (status body)
                    (if (not (em--2xx? status))
                        (k #f)
                        (let ((data (em--jstr (em--j (string->jsexpr body) 'data))))
                          (k (write-file-hex path (base64url-hex data)))))
                    (em--op-done)))))
      (begin
        (message "email: downloading …")
        (let ((conn (em--imap-connect)))
          (if (not conn)
              (k #f)
              (let ((ok
                     (and (em--imap-select conn em--all-mail)
                          (let ((uid (em--imap-uid-of conn id)))
                            (and uid
                                 (let* ((r (em--imap-cmd conn (string-append
                                                               "UID FETCH " (number->string uid)
                                                               " (BODY.PEEK[" (nth att 3) "]"
                                                               " BODY.PEEK[" (nth att 3) ".MIME])")))
                                        (fetch (filter (lambda (p)
                                                         (and (em--matches? " FETCH " (car p))
                                                              (pair? (cdr p))))
                                                       (nth r 0))))
                                   (and (em--imap-ok? r) (pair? fetch)
                                        (let* ((lits (cdr (car fetch)))
                                               (part-raw (car lits))
                                               (part-hs (em--parse-headers
                                                         (if (pair? (cdr lits)) (car (cdr lits)) "")))
                                               (cte (em--hdr part-hs "content-transfer-encoding")))
                                          (write-file-hex path (em--cte->hex part-raw cte))))))))))
                (em--imap-logout conn)
                (k ok)))))))

(define (email-view-save-attachment)
  (let ((atts (em--st 'view-atts))
        (id (em--st 'current)))
    (cond
      ((not id) (message "email: no message shown"))
      ((null? atts) (message "email: this message has no attachments"))
      ;; Attachment bytes are always fetched on demand — no offline copy.
      ((em--offline?)
       (message "email: attachments need a connection (not cached offline)"))
      (else
       (read-string
        (string-append "Attachment # (1-" (number->string (length atts)) "): ")
        (lambda (numstr)
          (let ((n (string->number (em--trim numstr))))
            (if (or (not n) (< n 1) (> n (length atts)))
                (message "email: no such attachment")
                (let* ((att (nth atts (- n 1)))
                       (scheme (if (>= (length att) 5) (nth att 4) "rest"))
                       (want (if (em--oauth?) "rest" "imap")))
                  (read-string
                   "Save to: "
                   (lambda (path)
                     (let ((path (em--expand-home (em--trim path))))
                       (define (finish ok)
                         (if ok
                             (message (string-append "email: saved " path))
                             (message "email: attachment download failed")))
                       (if (equal? scheme want)
                           (em--save-attachment-now id att path finish)
                           ;; Cache from the other backend: refresh it through
                           ;; this one, then save the same attachment index.
                           (em--fetch-message
                            id
                            (lambda (ok)
                              (let ((msg (and ok (em--read-message id))))
                                (if (and msg (>= (length (nth msg 2)) n))
                                    (begin
                                      (em--st! 'view-atts (nth msg 2))
                                      (em--save-attachment-now
                                       id (nth (nth msg 2) (- n 1)) path finish))
                                    (finish #f))))))))
                   (string-append "~/Downloads/" (nth att 0))))))))))))

;; ── folders + search (dispatch) ─────────────────────────────────────────────
;; The list shows one "folder" at a time: the local inbox (the default view),
;; a server-side preset (Unread/Starred/Sent/All Mail/Trash — each is a Gmail
;; query), or an ad-hoc search. Gmail query syntax works on both backends
;; (REST q= / IMAP X-GM-RAW); results merge into the db and pin the view.
;; `f` opens the folder popup, `i` jumps straight back to the inbox.
(define (em--goto-inbox)
  (em--st! 'search-ids #f)
  (em--st! 'folder #f)
  (em--list-render 'top))

;; Run query `q`, pinning the result view under `label` (the header name).
(define (em--do-search q label)
  (cond
    ((em--oauth?)
     (em--run-op
      (lambda ()
        (message (string-append "email: loading " label " …"))
        (em--api "GET"
                 (string-append "/gmail/v1/users/me/messages?maxResults=100&q="
                                (em--urlenc q)
                                ;; The API silently excludes trash/spam unless
                                ;; asked; only ask when the query wants them.
                                (if (em--matches? "in:(trash|spam)" q)
                                    "&includeSpamTrash=true"
                                    ""))
                 ""
                 (lambda (status body)
                   (if (not (em--2xx? status))
                       (begin
                         (message (string-append "email: " label " failed (HTTP "
                                                 (number->string status) ")"))
                         (em--op-done))
                       (let* ((j (string->jsexpr body))
                              (ids (map (lambda (m) (em--jstr (em--j m 'id)))
                                        (em--as-list (em--j j 'messages)))))
                         (em--st! 'fetchq
                                  (filter (lambda (id) (not (hash-try-get (em--st 'db) id)))
                                          ids))
                         (em--fetch-meta-loop
                          (lambda ()
                            (em--st! 'search-ids ids)
                            (em--st! 'folder label)
                            (em--save)
                            (em--list-render 'top)
                            (message (string-append "email: " label " — "
                                                    (number->string (length ids))
                                                    " messages"))
                            (em--op-done))))))))))
    (else
     (let ((conn (em--imap-connect)))
       (when conn
         (message (string-append "email: loading " label " …"))
         ;; Gmail's All Mail excludes Trash, so a trash query must SELECT the
         ;; Trash mailbox itself and take everything in it.
         (let* ((trash? (em--matches? "in:trash" q))
                (mbox (if trash? em--trash-box em--all-mail))
                (search (if trash? "ALL" (string-append "X-GM-RAW " (em--imap-quote q)))))
           (if (not (em--imap-select conn mbox))
               (begin (em--imap-logout conn) (message (string-append "email: " label " failed")))
               (let* ((uids (em--imap-search conn search))
                      (uids (let ((n (length uids)))   ; cap at the newest 100
                              (if (> n 100)
                                  (let drop ((xs uids) (k (- n 100)))
                                    (if (= k 0) xs (drop (cdr xs) (- k 1))))
                                  uids))))
                 (if (null? uids)
                     (begin (em--imap-logout conn)
                            (message (string-append "email: " label " — no messages")))
                     (let* ((uidset (em--join (map number->string uids) ","))
                            (envs (em--fetch-envelopes
                                   conn
                                   (string-append "UID FETCH " uidset " " em--fetch-items)
                                   #f)))
                       (em--imap-logout conn)
                       (for-each em--db-merge envs)
                       (em--save)
                       (em--st! 'search-ids (map (lambda (e) (hash-try-get e 'id)) envs))
                       (em--st! 'folder label)
                       (em--list-render 'top)
                       (message (string-append "email: " label " — "
                                               (number->string (length envs))
                                               " messages"))))))))))))

;; Offline, `s` (a server query) redirects to the local FTS search instead.
(define (email-list-search)
  (if (em--offline?)
      (email-search-local)
      (read-string
       "Gmail search: "
       (lambda (input)
         (let ((q (em--trim input)))
           (if (equal? q "")
               (em--goto-inbox)
               (em--do-search q (string-append "search: " q))))))))

;; Pin a LOCAL view: the ids of every db message carrying `label`, under
;; `name`. No network — works offline and instantly, for the folders that are
;; pure label filters (Unread, Starred).
(define (em--local-folder label name)
  (em--st! 'search-ids
           (filter (lambda (id)
                     (let ((e (hash-try-get (em--st 'db) id)))
                       (and e (member label (hash-try-get e 'labels)))))
                   (em--st 'ids)))
  (em--st! 'folder name)
  (em--list-render 'top)
  (message (string-append "email: " name " — "
                          (number->string (length (em--st 'search-ids))) " messages")))

;; The folder presets. Inbox and the pure label filters (Unread, Starred) are
;; local — instant, offline-capable. The rest are server-side Gmail queries;
;; offline they report that a connection is needed.
(define (email-folder-inbox)   (em--goto-inbox))
(define (email-folder-unread)  (em--local-folder "UNREAD" "Unread"))
(define (email-folder-starred) (em--local-folder "STARRED" "Starred"))
(define (em--server-folder q label)
  (if (em--offline?)
      (message (string-append "email: " label " needs a connection (offline mode)"))
      (em--do-search q label)))
(define (email-folder-sent)    (em--server-folder "in:sent" "Sent"))
(define (email-folder-all)     (em--server-folder "-in:spam -in:trash" "All Mail"))
(define (email-folder-trash)   (em--server-folder "in:trash" "Trash"))

;; `?` — the everything menu: every command in the package, grouped, so no
;; keybinding has to be remembered. One per mode (list / view).
(define (email-menu)
  (transient "Email"
             (list (list "Message"
                         (list "o" "Open"          'email-list-open)
                         (list "C" "Compose"       'email-compose)
                         (list "R" "Reply"         'email-list-reply)
                         (list "E" "Reply all"     'email-list-reply-all))
                   (list "Flags"
                         (list "A" "Archive"       'email-list-archive)
                         (list "D" "Trash"         'email-list-trash)
                         (list "U" "Toggle unread" 'email-list-toggle-unread)
                         (list "*" "Toggle star"   'email-list-toggle-star))
                   (list "View"
                         (list "f" "Folders…"      'email-folders)
                         (list "i" "Inbox"         'email-folder-inbox)
                         (list "s" "Server search…" 'email-list-search)
                         (list "/" "Local search…" 'email-search-local)
                         (list "g" "Refresh"       'email-list-refresh)
                         (list "G" "Sync"          'email-sync))
                   (list "Account"
                         (list "a" "Next account"  'email-cycle-account)
                         (list "w" "Switch account…" 'email-switch-account)
                         (list "n" "New account…"  'email-add-account)
                         (list "L" "Log in"        'email-login))
                   (list "Offline"
                         (list "O" "Outbox"        'email-outbox)
                         (list "F" "Flush outbox"  'email-outbox-flush)
                         (list "M" "Toggle live/offline" 'email-toggle-mode))
                   (list "Archive"
                         (list "m" "Export Maildir…" 'email-export-maildir)
                         (list "x" "Rebuild index" 'email-index)
                         (list "q" "Quit"          'email-list-quit)))))

(define (email-view-menu)
  (transient "Email message"
             (list (list "Message"
                         (list "R" "Reply"         'email-view-reply)
                         (list "E" "Reply all"     'email-view-reply-all)
                         (list "n" "Next"          'email-view-next)
                         (list "p" "Previous"      'email-view-prev)
                         (list "l" "Follow link"   'email-view-follow)
                         (list "b" "Open in Gmail" 'email-view-browse))
                   (list "Flags"
                         (list "A" "Archive"       'email-view-archive)
                         (list "D" "Trash"         'email-view-trash))
                   (list "Attachments"
                         (list "W" "Save attachment…" 'email-view-save-attachment))
                   (list "Patch / git"
                         (list "p" "git am (apply)"   'email-view-git-am)
                         (list "3" "git am --3way"    'email-view-git-am-3way)
                         (list "z" "git am --abort"   'email-view-git-am-abort)
                         (list "P" "Save .patch…"     'email-view-save-patch))
                   (list "Other"
                         (list "U" "Toggle unread"  'email-view-toggle-unread)
                         (list "q" "Back to list"   'email-view-quit)))))

;; The compose menu — bound to C-c C-t (the buffer is editable, so a bare `?`
;; would self-insert). Lists every compose action, including "send later"
;; (queue to the outbox even in live mode).
(define (email-compose-menu)
  (transient "Compose"
             (list (list "Send"
                         (list "c" "Send now"        'email-compose-send)
                         (list "l" "Send later (outbox)" 'email-compose-send-later)
                         (list "k" "Discard"         'email-compose-cancel))
                   (list "Add"
                         (list "a" "Attach file…"    'email-compose-attach)
                         (list "b" "Add Bcc"         'email-compose-toggle-bcc)
                         (list "i" "Complete address" 'completion-at-point)))))

;; `f` — the folder popup (magit-style transient; pressing a key runs it).
(define (email-folders)
  (transient "Email folders"
             (list (list "Folders"
                         (list "i" "Inbox (local)" 'email-folder-inbox)
                         (list "u" "Unread"        'email-folder-unread)
                         (list "*" "Starred"       'email-folder-starred)
                         (list "t" "Sent"          'email-folder-sent)
                         (list "l" "All Mail"      'email-folder-all)
                         (list "d" "Trash"         'email-folder-trash))
                   (list "Search"
                         (list "s" "Server search…" 'email-list-search)
                         (list "/" "Local search…"  'email-search-local)
                         (list "x" "Rebuild index"  'email-index))
                   (list "Offline"
                         (list "O" "Outbox"         'email-outbox)
                         (list "F" "Flush outbox"   'email-outbox-flush)
                         (list "M" "Toggle mode"    'email-toggle-mode)))))

;; ── commands ────────────────────────────────────────────────────────────────
(define (email)
  (em--load)
  (em--list-render 'top)
  (em--arm-timer)
  (when (null? (em--st 'ids))
    (message
     (if (em--oauth?)
         (if (equal? (em--client-id) "")
             "email: set the \"email-client-id\" option, then L to log in (see README)"
             "email: press L to log in, G to sync")
         "email: press L to log in with a Gmail app password, then G to sync"))))

;; Log in via the active method's flow.
(define (email-login)
  (if (em--oauth?)
      (em--login-oauth)
      (read-string
       "Gmail address: "
       (lambda (addr-in)
         (let ((addr (em--trim addr-in)))
           (if (equal? addr "")
               (message "email: no address given")
               (read-string
                "App password (from myaccount.google.com/apppasswords): "
                (lambda (pass-in)
                  ;; App passwords display as four spaced groups — strip spaces.
                  (let ((pass (replace-regexp-in-string "\\s" "" pass-in)))
                    (if (equal? pass "")
                        (message "email: no password given")
                        (begin
                          (em--st! 'me addr)
                          (em--st! 'app-pass pass)
                          (em--st! 'pass-loaded #t)
                          (message "email: verifying …")
                          (let ((conn (em--imap-connect)))
                            (if (not conn)
                                (em--st! 'app-pass #f)   ; keep the bad one out of the keychain
                                (begin
                                  (em--imap-logout conn)
                                  (em--save-app-pass pass)
                                  (em--load)
                                  (em--save)             ; persist 'me in the index header
                                  (message (string-append "email: logged in as " addr
                                                          " — press G to sync"))))))))))))))))

;; ── account switching ───────────────────────────────────────────────────────
;; Save the active account's store, wipe the volatile per-account state, point
;; at the new account, and load its store. Refused mid-sync / mid-request /
;; mid-login, since in-flight continuations belong to the old account.
(define (em--reset-account-state)
  (for-each
   (lambda (kv) (em--st! (car kv) (cdr kv)))
   (list (cons 'db (hash)) (cons 'ids '()) (cons 'loaded #f)
         (cons 'history-id "") (cons 'uid-validity "") (cons 'max-uid 0)
         (cons 'me "") (cons 'view '()) (cons 'view-atts '())
         (cons 'current #f) (cons 'search-ids #f) (cons 'folder #f) (cons 'fetchq '())
         (cons 'new-count 0) (cons 'pending-ops '())
         (cons 'cacheq '()) (cons 'caching #f) (cons 'outbox-files '())
         (cons 'access-token #f) (cons 'token-expiry 0)
         (cons 'refresh-token #f) (cons 'token-loaded #f)
         (cons 'app-pass #f) (cons 'pass-loaded #f))))

;; ── account wizard ──────────────────────────────────────────────────────────
;; M-x email-add-account — guided setup: method → address → (oauth: client-id
;; → client-secret | app-password: the password). Secrets are appended to
;; ~/.authinfo (created 600 if missing); the account itself is appended to
;; the email-client.conf Scheme file, which em--accounts merges in.

(define em--conf-fields
  (list 'name 'method 'query 'address 'from-name 'imap-host 'smtp-host 'mode
        'maildir 'fetch-count 'auto-sync-minutes 'authinfo 'client-id 'client-secret))

(define (em--conf-escape s)
  (list->string
   (reverse
    (let loop ((cs (string->list s)) (out '()))
      (cond ((null? cs) out)
            ((or (equal? (car cs) #\") (equal? (car cs) #\\))
             (loop (cdr cs) (cons (car cs) (cons #\\ out))))
            (else (loop (cdr cs) (cons (car cs) out))))))))

(define (em--conf-render-account a)
  (string-append
   " (hash"
   (apply string-append
          (map (lambda (f)
                 (let ((v (em--j a f)))
                   (if (and (string? v) (not (equal? v "")))
                       (string-append " '" (symbol->string f)
                                      " \"" (em--conf-escape v) "\"")
                       "")))
               em--conf-fields))
   ")\n"))

(define (em--conf-render accounts)
  (string-append
   ";; macros-email-client accounts — written by M-x email-add-account and\n"
   ";; yours to edit. Must evaluate to a LIST OF ACCOUNT HASHES; every field\n"
   ";; but 'name is optional (see the package README for the field list).\n"
   ";; Secrets belong in ~/.authinfo, not here. Merged over the\n"
   ";; \"email-accounts\" option by 'name. The wizard rewrites this file,\n"
   ";; keeping known fields only — comments do not survive a rewrite.\n"
   "(list\n"
   (apply string-append (map em--conf-render-account accounts))
   ")\n"))

(define (em--conf-save accounts)
  (let ((path (em--expand-home (em--conf-file))))
    (write-file path (em--conf-render accounts))
    (call-process-full "chmod" (list "600" path) "")))

(define (em--ends-newline? s)
  (let ((n (string-length s)))
    (and (> n 0) (equal? (substring s (- n 1) n) "\n"))))

(define (em--contains-space? s)
  (let loop ((cs (string->list s)))
    (cond ((null? cs) #f)
          ((equal? (car cs) #\space) #t)
          (else (loop (cdr cs))))))

(define (em--authinfo-quote s)
  (if (em--contains-space? s) (string-append "\"" s "\"") s))

;; Append (machine login secret) entries to the authinfo file, creating a
;; plaintext ~/.authinfo 600 if none exists. When ~/.authinfo.gpg exists the
;; append goes THERE — decrypt, extend, re-encrypt to the default key — so an
;; encrypted setup never sprouts a plaintext sibling. An entry whose
;; machine+login already resolve is skipped, so re-running the wizard never
;; duplicates (or shadows) a line.
(define (em--authinfo-append! entries)
  (let* ((gpg-path (em--expand-home "~/.authinfo.gpg"))
         (use-gpg (file-exists? gpg-path))
         (path (if use-gpg gpg-path (em--expand-home "~/.authinfo")))
         (existing (cond (use-gpg (em--authinfo-text "~/.authinfo.gpg"))
                         ((file-exists? path) (read-file path))
                         (else ""))))
    (if (and use-gpg (not (string? existing)))
        ;; Decrypt failed: writing would clobber the entries we can't read.
        (message "email: could not decrypt ~/.authinfo.gpg — secrets NOT saved")
        (let ((add (filter (lambda (e)
                             (not (em--authinfo-find-in existing (nth e 0) (nth e 1))))
                           entries)))
          (when (pair? add)
            (let ((text (string-append
                         existing
                         (if (or (equal? existing "") (em--ends-newline? existing)) "" "\n")
                         (apply string-append
                                (map (lambda (e)
                                       (string-append
                                        "machine " (nth e 0) " login " (nth e 1)
                                        " password " (em--authinfo-quote (nth e 2)) "\n"))
                                     add)))))
              (if use-gpg
                  (let ((r (call-process-full
                            (em--gpg-bin)
                            (list "--batch" "--yes" "--quiet"
                                  "--default-recipient-self" "-e" "-o" path)
                            text)))
                    (when (not (equal? (car r) "0"))
                      (message "email: gpg encrypt failed — secrets NOT saved")))
                  (write-file path text))
              (call-process-full "chmod" (list "600" path) "")))
          (em--st! 'authinfo-cache (hash))))))

(define (em--wizard-finish addr method entries)
  (em--authinfo-append! entries)
  (em--conf-save (em--merge-accounts (em--conf-accounts)
                                     (list (hash 'name addr 'method method))))
  (em--do-switch addr)
  (message (string-append "email: added " addr " (" method ") — config in "
                          (em--conf-file) ", secrets in ~/.authinfo; L to log in")))

(define (email-add-account)
  (read-string
   "Account type (oauth / app-password): "
   (lambda (t0)
     (let ((method (let ((t (em--downcase (em--trim t0))))
                     (cond ((or (equal? t "o") (equal? t "oauth")) "oauth")
                           ((or (equal? t "a") (equal? t "app-password")
                                (equal? t "app password")) "app-password")
                           (else #f)))))
       (if (not method)
           (message "email: account type must be oauth or app-password")
           (read-string
            "Email address: "
            (lambda (a0)
              (let ((addr (em--trim a0)))
                (cond
                  ((equal? addr "") (message "email: empty address"))
                  ((em--account-exists? addr)
                   (message (string-append "email: account " addr " is already configured")))
                  ((equal? method "oauth")
                   (read-string
                    "OAuth client-id: "
                    (lambda (id0)
                      (let ((cid (em--trim id0)))
                        (if (equal? cid "")
                            (message "email: empty client-id")
                            (read-string
                             "OAuth client-secret: "
                             (lambda (sec0)
                               (let ((sec (em--trim sec0)))
                                 (if (equal? sec "")
                                     (message "email: empty client-secret")
                                     (em--wizard-finish
                                      addr "oauth"
                                      (list (list addr "client-id" cid)
                                            (list addr "client-secret" sec))))))))))))
                  (else
                   (read-string
                    "App password (myaccount.google.com/apppasswords): "
                    (lambda (p0)
                      (let ((pw (em--trim p0)))
                        (if (equal? pw "")
                            (message "email: empty app password")
                            (em--wizard-finish
                             addr "app-password"
                             (list (list (em--knob "email-imap-host" "imap.gmail.com")
                                         addr pw)))))))))))))))))

(define (em--do-switch name)
  (cond
    ((em--st 'syncing) (message "email: cannot switch accounts during a sync"))
    ((em--st 'indexing) (message "email: cannot switch accounts during indexing — C-g cancels it"))
    ((em--st 'exporting) (message "email: cannot switch accounts during an export"))
    ((em--st 'caching) (message "email: cannot switch accounts during the offline cache"))
    ((em--st 'busy)    (message "email: cannot switch accounts while a request is in flight"))
    ((em--st 'auth)    (message "email: cannot switch accounts during a login"))
    ((not (em--account-exists? name))
     (message (string-append "email: no account \"" name
                             "\" — configure the \"email-accounts\" option")))
    ((equal? name (em--account))
     (message (string-append "email: already on " name)))
    (else
     (when (em--st 'loaded) (em--save))
     (em--reset-account-state)
     (em--st! 'account name)
     (em--load)
     (em--list-render 'top)
     (message (string-append "email: switched to " name
                             " (" (if (em--oauth?) "oauth" "app-password") ")"
                             (if (em--logged-in?) "" " — press L to log in"))))))

;; M-x email-switch-account — prompt with the configured names.
(define (email-switch-account)
  (let ((names (map em--acc-name (em--accounts))))
    (if (null? (cdr names))
        (message "email: only one account — set the \"email-accounts\" option")
        (read-string
         (string-append "Account (" (em--join names " / ") "): ")
         (lambda (input)
           (let ((name (em--trim input)))
             (when (not (equal? name "")) (em--do-switch name))))))))

;; `a` in the list buffer — hop to the next configured account, wrapping.
(define (email-cycle-account)
  (let* ((names (map em--acc-name (em--accounts)))
         (cur (em--account)))
    (if (null? (cdr names))
        (message "email: only one account — set the \"email-accounts\" option")
        (em--do-switch
         (let loop ((xs names))
           (cond ((null? xs) (car names))
                 ((equal? (car xs) cur)
                  (if (pair? (cdr xs)) (car (cdr xs)) (car names)))
                 (else (loop (cdr xs)))))))))

(define (email-list-open)
  (let ((id (em--id-at-point)))
    (if id
        (begin (em--list-render 'keep) (em--open id))
        (message "email: no message on this line"))))

(define (em--list-act thunk)         ; run `thunk` on the id at point, redraw
  (let ((id (em--id-at-point)))
    (if (not id)
        (message "email: no message on this line")
        (let ((line (buffer-line)))
          (thunk id)
          (em--list-render 'keep)
          (goto-line line)))))

(define (email-list-archive) (em--list-act (lambda (id) (em--queue-op id "archive"))))
(define (email-list-trash)   (em--list-act (lambda (id) (em--queue-op id "trash"))))

(define (email-list-toggle-unread)
  (em--list-act
   (lambda (id)
     (let ((e (hash-try-get (em--st 'db) id)))
       (em--queue-op id (if (member "UNREAD" (hash-try-get e 'labels)) "read" "unread"))))))

(define (email-list-toggle-star)
  (em--list-act
   (lambda (id)
     (let ((e (hash-try-get (em--st 'db) id)))
       (em--queue-op id (if (member "STARRED" (hash-try-get e 'labels)) "unstar" "star"))))))

(define (email-list-reply)
  (let ((id (em--id-at-point)))
    (if id (em--reply id #f) (message "email: no message on this line"))))

(define (email-list-reply-all)
  (let ((id (em--id-at-point)))
    (if id (em--reply id #t) (message "email: no message on this line"))))

(define (email-list-refresh) (em--list-render 'keep))
(define (email-list-quit) (switch-to-buffer "*scratch*"))

;; view-buffer commands
(define (email-view-quit)
  (let* ((cur (em--st 'current))
         (view (em--st 'view))
         (line (let loop ((xs view) (i 0))
                 (cond ((null? xs) 'top)
                       ((equal? (car xs) cur) (+ i (em--st 'view-offset)))
                       (else (loop (cdr xs) (+ i 1)))))))
    (em--st! 'current #f)
    (em--list-render line)))

(define (em--view-step dir)
  (let* ((view (em--st 'view))
         (cur (em--st 'current)))
    (let loop ((xs view) (i 0))
      (cond
        ((null? xs) (message "email: message not in the list"))
        ((equal? (car xs) cur)
         (let ((j (+ i dir)))
           (if (and (>= j 0) (< j (length view)))
               (em--open (nth view j))
               (message "email: no more messages"))))
        (else (loop (cdr xs) (+ i 1)))))))

(define (email-view-next) (em--view-step 1))
(define (email-view-prev) (em--view-step -1))

(define (email-view-reply)
  (let ((id (em--st 'current)))
    (if id (em--reply id #f) (message "email: no message shown"))))

(define (email-view-reply-all)
  (let ((id (em--st 'current)))
    (if id (em--reply id #t) (message "email: no message shown"))))

(define (email-view-toggle-unread)
  (let ((id (em--st 'current)))
    (if (not id)
        (message "email: no message shown")
        (let ((e (hash-try-get (em--st 'db) id)))
          (em--queue-op id (if (member "UNREAD" (hash-try-get e 'labels)) "read" "unread"))
          (message (string-append "email: marked "
                                  (if (member "UNREAD" (hash-try-get (hash-try-get (em--st 'db) id) 'labels))
                                      "unread" "read")))))))

(define (email-view-archive)
  (let ((id (em--st 'current)))
    (when id
      (em--queue-op id "archive")
      (message "email: archived"))))

(define (email-view-trash)
  (let ((id (em--st 'current)))
    (when id
      (em--queue-op id "trash")
      (email-view-quit)
      (message "email: moved to trash"))))

;; ids are hex REST ids in both backends, so the Gmail-web deep link works.
(define (email-view-browse)
  (let ((id (em--st 'current)))
    (if id
        (open-url (string-append "https://mail.google.com/mail/u/0/#all/" id))
        (message "email: no message shown"))))

;; ── git patch workflow (git am) ─────────────────────────────────────────────
;; Emailed patches (git send-email / format-patch) ARE RFC 822 messages whose
;; body is a diff with the commit metadata in the headers — exactly what
;; `git am` consumes. These commands fetch the raw message and pipe it to git
;; in a chosen repo, so a patch series in your inbox becomes commits without
;; leaving the editor. The default repo is the "email-git-repo" option (or the
;; editor's current project dir); each command re-prompts so you can override.
(define (em--git-repo-default)
  (let ((opt (em--trim (em--knob "email-git-repo" ""))))
    (if (equal? opt "") "" (em--expand-home opt))))

;; Fetch the RAW RFC 822 bytes of message `id` (hex), then call `(k hex)` —
;; or `(k #f)` on failure. OAuth: format=raw (async op). IMAP: BODY.PEEK[].
(define (em--with-raw id k)
  (if (em--oauth?)
      (em--run-op
       (lambda ()
         (message "email: fetching raw message …")
         (em--api "GET" (string-append "/gmail/v1/users/me/messages/" id "?format=raw") ""
                  (lambda (status body)
                    (k (if (em--2xx? status)
                           (base64url-hex (em--jstr (em--j (string->jsexpr body) 'raw)))
                           #f))
                    (em--op-done)))))
      (let ((conn (em--imap-connect)))
        (if (not conn)
            (k #f)
            (let ((hex
                   (and (em--imap-select conn em--all-mail)
                        (let ((uid (em--imap-uid-of conn id)))
                          (and uid
                               (let* ((r (em--imap-cmd conn (string-append
                                                             "UID FETCH " (number->string uid)
                                                             " (BODY.PEEK[])")))
                                      (fetch (filter (lambda (p) (and (em--matches? " FETCH " (car p))
                                                                      (pair? (cdr p))))
                                                     (nth r 0))))
                                 (and (em--imap-ok? r) (pair? fetch)
                                      (em--latin1->hex (car (cdr (car fetch)))))))))))
              (em--imap-logout conn)
              (k (or hex #f)))))))

;; Write the current message's raw bytes to a temp .patch, run `git <args>`
;; in `repo`, and report the exit status + git's own stderr.
(define (em--git-run id repo0 args label)
  ;; Resolve the repo to an ABSOLUTE path first: `git -C` and the spawned
  ;; process inherit the editor's cwd (`/` under a GUI launch), so a relative
  ;; path would resolve against the wrong place, and `~` never expands without
  ;; a shell. Expanding here makes the .git guard and the invocation agree.
  (let ((repo (em--expand-home (em--trim repo0))))
    (cond
      ((not id) (message "email: no message shown"))
      ((equal? repo "") (message "email: no git repository given"))
      ((not (starts-with? repo "/"))
       (message (string-append "email: give an absolute repo path (got \"" repo "\")")))
      ((not (file-directory? (path-join repo ".git")))
       (message (string-append "email: " repo " is not a git repository")))
      (else
       (em--with-raw
        id
        (lambda (hex)
          (if (not hex)
              (message "email: could not fetch the raw message")
              (let ((tmp (path-join (em--data-dir) "patch.eml")))
                (write-file-hex tmp hex)
                (let* ((r (call-process-full "git" (append (list "-C" repo) args (list tmp)) ""))
                     (code (car r)) (out (car (cdr r))) (err (car (cdr (cdr r)))))
                (delete-file tmp)
                (if (equal? code "0")
                    (message (string-append "email: " label " ✓ " (em--trim out)))
                    (message (string-append "email: " label " failed — "
                                            (em--trim (if (equal? (em--trim err) "") out err))))))))))))))

(define (em--git-prompt id args label)
  (read-string (string-append "git " label " into repo: ")
               (lambda (repo) (em--git-run id repo args label))
               (em--git-repo-default)))

(define (email-view-git-am)
  (em--git-prompt (em--st 'current) (list "am") "am"))
(define (email-view-git-am-3way)
  (em--git-prompt (em--st 'current) (list "am" "--3way") "am --3way"))
;; abort a series in progress. Same absolute-path resolution as em--git-run.
(define (email-view-git-am-abort)
  (read-string "git am --abort in repo: "
               (lambda (repo0)
                 (let ((repo (em--expand-home (em--trim repo0))))
                   (if (not (starts-with? repo "/"))
                       (message "email: give an absolute repo path")
                       (let ((r (call-process-full "git" (list "-C" repo "am" "--abort") "")))
                         (message (if (equal? (car r) "0") "email: git am aborted"
                                      (string-append "email: " (em--trim (car (cdr (cdr r)))))))))))
               (em--git-repo-default)))

;; Save the raw message as a .patch/.eml file (for `git am` later, or archiving).
(define (email-view-save-patch)
  (let ((id (em--st 'current)))
    (if (not id)
        (message "email: no message shown")
        (read-string
         "Save patch to: "
         (lambda (path)
           (let ((path (em--expand-home (em--trim path))))
             (em--with-raw id
                           (lambda (hex)
                             (if (and hex (write-file-hex path hex))
                                 (message (string-append "email: saved " path))
                                 (message "email: could not save the patch"))))))
         (string-append "~/" (let ((s (hash-try-get (hash-try-get (em--st 'db) id) 'subject)))
                               (replace-regexp-in-string "[^A-Za-z0-9]+" "-" (em--truncate s 40)))
                        ".patch")))))

;; enter / click on a link: pick the [N] marker at (or after) the cursor
;; column on this line and open its URL in the default browser. This is the
;; ONLY way message content reaches the network, and it is always an explicit
;; user action on a visible marker — never automatic.
(define (email-view-follow)
  (let* ((lines (em--st 'view-lines))
         (idx (buffer-line))
         (text (if (and (>= idx 0) (< idx (length lines))) (nth lines idx) ""))
         (markers (emw--line-markers text)))
    (if (null? markers)
        (message "email: no link on this line")
        (let* ((col (- (point) (car (line-bounds))))
               (n (emw--pick-marker markers col))
               (url (em--aget (em--st 'view-links) n)))
          (if url
              (begin (open-url url)
                     (message (string-append "email: opened " url)))
              (message "email: no link here"))))))

;; ── Maildir export (mu / notmuch interop) ───────────────────────────────────
;; `M-x email-export-maildir` downloads the account's ENTIRE mailbox as a
;; Maildir of byte-exact RFC 822 files — the format mu and notmuch index.
;; OAuth: `messages.get?format=raw` returns the original message base64url-
;; encoded; decoded via `base64url-hex` → `write-file-hex`, so bytes survive
;; exactly. IMAP: `BODY.PEEK[]` raw fetches from All Mail. Gmail labels map to
;; Maildir info flags (ASCII order D<F<S<T): D draft, F starred, S read,
;; T trashed. Files land in <dir>/cur/ as "<epoch>.<id>.macros:2,<flags>".
;;
;; Resumable: exported ids persist in <dir>/.macros-exported; re-running
;; skips them and picks up only new mail. The OAuth path is async (the editor
;; stays usable; `M-x email-export-cancel` stops it between messages); the
;; IMAP path blocks the engine until done — prefer an oauth account for a
;; large first export.
(define (em--maildir-flags labels)
  (string-append (if (member "DRAFT" labels) "D" "")
                 (if (member "STARRED" labels) "F" "")
                 (if (member "UNREAD" labels) "" "S")
                 (if (member "TRASH" labels) "T" "")))

(define (em--maildir-file dir id date labels)
  (path-join dir (string-append "cur/" (number->string date) "." id
                                ".macros:2," (em--maildir-flags labels))))

(define (em--export-manifest dir) (path-join dir ".macros-exported"))

(define (em--export-seen-load dir)
  (let ((ids (if (file-exists? (em--export-manifest dir))
                 (filter (lambda (l) (not (equal? l "")))
                         (em--split-char (read-file (em--export-manifest dir)) #\newline))
                 '())))
    (em--st! 'export-old ids)
    (em--st! 'export-new '())
    (em--st! 'export-seen
             (let loop ((xs ids) (h (hash)))
               (if (null? xs) h (loop (cdr xs) (hash-insert h (car xs) #t)))))))

(define (em--export-seen? id) (hash-try-get (em--st 'export-seen) id))
(define (em--export-mark id)
  (em--st! 'export-seen (hash-insert (em--st 'export-seen) id #t))
  (em--st! 'export-new (cons id (em--st 'export-new))))

(define (em--export-manifest-save)
  (write-file (em--export-manifest (em--st 'export-dir))
              (string-append
               (em--join (append (em--st 'export-old) (reverse (em--st 'export-new))) "\n")
               "\n")))

(define (em--export-finish note)
  (em--export-manifest-save)
  (let ((quiet (em--st 'export-quiet)))
    (em--st! 'exporting #f)
    (when (or (not quiet) (> (em--st 'export-count) 0))
      (message (string-append "email: " (if quiet "maildir mirror " "export ") note " — "
                              (number->string (em--st 'export-count)) " written, "
                              (number->string (em--st 'export-skip)) " already present → "
                              (em--st 'export-dir))))))

(define (email-export-cancel)
  (if (equal? (em--st 'exporting) 'run)
      (begin (em--st! 'exporting 'cancel)
             (message "email: export will stop after the current message"))
      (message "email: no export running")))

;; One REST page of ids → the fetch queue; "" token = the first page.
(define (em--export-page token)
  (em--api "GET"
           (string-append "/gmail/v1/users/me/messages?maxResults=500"
                          (if (equal? token "") ""
                              (string-append "&pageToken=" (em--urlenc token))))
           ""
           (lambda (status body)
             (if (not (em--2xx? status))
                 (begin (em--export-finish (string-append "failed (HTTP " (number->string status) ")"))
                        (em--op-done))
                 (let ((j (string->jsexpr body)))
                   (em--st! 'export-queue
                            (map (lambda (m) (em--jstr (em--j m 'id)))
                                 (em--as-list (em--j j 'messages))))
                   (em--st! 'export-token (em--jstr (em--j j 'nextPageToken)))
                   (em--export-next))))))

;; Drain the queue: skip already-exported ids synchronously, then fetch one
;; raw message, write it, and recur — one request in flight at a time.
(define (em--export-next)
  (if (equal? (em--st 'exporting) 'cancel)
      (begin (em--export-finish "cancelled") (em--op-done))
      (let skip ((q (em--st 'export-queue)))
        (cond
          ((and (pair? q) (em--export-seen? (car q)))
           (em--st! 'export-skip (+ 1 (em--st 'export-skip)))
           (skip (cdr q)))
          ((null? q)
           (em--st! 'export-queue '())
           (let ((token (em--st 'export-token)))
             (if (equal? token "")
                 (begin (em--export-finish "done") (em--op-done))
                 (begin (em--export-manifest-save)     ; page boundary checkpoint
                        (message (string-append "email: exporting … "
                                                (number->string (em--st 'export-count)) " so far"))
                        (em--export-page token)))))
          (else
           (em--st! 'export-queue (cdr q))
           (let ((id (car q)))
             (em--api "GET"
                      (string-append "/gmail/v1/users/me/messages/" id "?format=raw")
                      ""
                      (lambda (status body)
                        (when (em--2xx? status)
                          (let* ((j (string->jsexpr body))
                                 (raw (em--jstr (em--j j 'raw)))
                                 (labels (map em--jstr (em--as-list (em--j j 'labelIds))))
                                 (date (quotient (or (string->number (em--jstr (em--j j 'internalDate))) 0)
                                                 1000)))
                            (when (and (not (equal? raw ""))
                                       (write-file-hex
                                        (em--maildir-file (em--st 'export-dir) id date labels)
                                        (base64url-hex raw)))
                              (em--export-mark id)
                              (em--st! 'export-count (+ 1 (em--st 'export-count))))))
                        (em--export-next)))))))))

;; The blocking IMAP export: everything in All Mail, one UID at a time.
(define (em--export-imap dir)
  (let ((conn (em--imap-connect)))
    (if (not conn)
        (em--st! 'exporting #f)
        (if (not (em--imap-select conn em--all-mail))
            (begin (em--imap-logout conn) (em--export-finish "failed (SELECT)"))
            (let ((uids (em--imap-search conn "ALL")))
              (let loop ((us uids) (n 0))
                (if (null? us)
                    (begin (em--imap-logout conn) (em--export-finish "done"))
                    (let* ((r (em--imap-cmd conn (string-append
                                                  "UID FETCH " (number->string (car us))
                                                  " (UID X-GM-MSGID X-GM-LABELS FLAGS INTERNALDATE BODY.PEEK[])")))
                           (fetch (filter (lambda (p) (and (em--matches? " FETCH " (car p))
                                                           (pair? (cdr p))))
                                          (nth r 0))))
                      (when (and (em--imap-ok? r) (pair? fetch))
                        ;; em--parse-fetch reads the header block out of the
                        ;; raw message literal, so it works unchanged here.
                        (let ((e (em--parse-fetch (car fetch) #f))
                              (raw (car (cdr (car fetch)))))
                          (when (and e (not (em--export-seen? (hash-try-get e 'id))))
                            (when (write-file-hex
                                   (em--maildir-file dir (hash-try-get e 'id)
                                                     (hash-try-get e 'date)
                                                     (hash-try-get e 'labels))
                                   (em--latin1->hex raw))
                              (em--export-mark (hash-try-get e 'id))
                              (em--st! 'export-count (+ 1 (em--st 'export-count)))))))
                      (when (= 0 (modulo n 25))
                        (message (string-append "email: exporting … "
                                                (number->string (em--st 'export-count)) " written")))
                      (loop (cdr us) (+ n 1))))))))))

(define (email-export-maildir)
  (cond
    ((em--st 'exporting) (message "email: an export is already running"))
    ((em--st 'syncing) (message "email: wait for the sync to finish"))
    (else
     (em--load)
     (read-string
      "Export Maildir to: "
      (lambda (input)
        (let ((dir (em--expand-home (em--trim input))))
          (when (not (equal? dir ""))
            (em--st! 'exporting 'run)
            (em--st! 'export-quiet #f)
            (em--st! 'export-dir dir)
            (em--st! 'export-count 0)
            (em--st! 'export-skip 0)
            (em--export-seen-load dir)
            (if (em--oauth?)
                (em--run-op (lambda () (em--export-page "")))
                (em--export-imap dir)))))
      (path-join (em--acct-dir) "maildir")))))

;; ── local full-text index (this package's own "mu index") ───────────────────
;; `M-x email-index` builds/updates a per-account SQLite FTS5 index over the
;; account's Maildir — the same job `mu index` does, but owned by the package,
;; queried with `email-search-local` (or `/` in the list). BM25-ranked, offline,
;; over the whole archive. Incremental: files already in the index are skipped,
;; so re-running only adds new mail. Requires a Maildir (run
;; `email-export-maildir` first, or the auto-mirror `email-maildir` option).
(define (em--index-db-file) (path-join (em--acct-dir) "search.db"))

;; The Maildir to index: the configured mirror dir, else <account>/maildir.
(define (em--index-source-dir)
  (or (em--maildir-auto-dir)
      (let ((d (path-join (em--acct-dir) "maildir"))) d)))

;; A Maildir filename is "<epoch>.<id>.macros:2,<flags>"; pull the id out.
(define (em--maildir-id filename)
  (em--cap "^[0-9]+\\.([^.]+)\\.macros:2," (basename filename)))

;; Open the index db, creating the FTS5 schema on first use. Returns the db id
;; (0 on failure). `id` is UNINDEXED (a stored key, not a search column).
(define (em--index-open)
  (let ((db (sqlite-open (em--index-db-file))))
    (if (= db 0)
        (begin (message (string-append "email: cannot open index — " (sqlite-last-error))) 0)
        (if (sqlite-exec db
                         (string-append
                          "CREATE VIRTUAL TABLE IF NOT EXISTS mail USING fts5("
                          "id UNINDEXED, sender, recipients, subject, "
                          "date UNINDEXED, body, tokenize='porter unicode61');")
                         '())
            db
            (begin (sqlite-close db)
                   (message (string-append "email: index schema failed — " (sqlite-last-error)))
                   0)))))

;; The set of ids already indexed, as a hash (for incremental skip).
(define (em--index-existing db)
  (let loop ((rows (sqlite-query db "SELECT id FROM mail" '())) (h (hash)))
    (if (null? rows) h (loop (cdr rows) (hash-insert h (car rows) #t)))))

;; Body text for the SEARCH INDEX — deliberately NOT `em--pick-body-mime`. The
;; viewer's picker eagerly runs the vendored reader-mode layout engine
;; (`em--html->text`) on the HTML part of EVERY message, which averages ~0.9s
;; and can take several SECONDS on one pathological message — fine once, for the
;; message you're reading, but ruinous across a whole-archive index (it blocked
;; the engine so hard C-g/`q` couldn't get through). The index only needs
;; searchable words, not faithful layout, so: prefer the plain part, and fall
;; back to the LIGHT regex strip (`em--html->text-basic`) for HTML-only mail.
;; That drops per-message cost to a few ms, so index chunks stay short and the
;; UI stays responsive.
(define (em--index-body leaves)
  (or (let loop ((ps leaves))
        (cond ((null? ps) #f)
              ((and (equal? (hash-try-get (car ps) 'mime) "text/plain")
                    (equal? (hash-try-get (car ps) 'filename) ""))
               (em--body-clean (em--leaf-text (car ps))))
              (else (loop (cdr ps)))))
      (let loop ((ps leaves))
        (cond ((null? ps) "")
              ((and (equal? (hash-try-get (car ps) 'mime) "text/html")
                    (equal? (hash-try-get (car ps) 'filename) ""))
               (em--html->text-basic (em--leaf-text (car ps))))
              (else (loop (cdr ps)))))))

;; Parse one raw RFC 822 message into the row we index: decoded from/to/
;; subject headers + the plain-text body. `date` is the filename epoch.
(define (em--index-row id date raw)
  (let* ((sp (em--split-raw raw))
         (hs (em--parse-headers (car sp)))
         (leaves (em--mime-leaves raw ""))
         (body (em--index-body leaves)))
    (list id
          (em--sanitize (em--decode-header (em--hdr hs "from")))
          (em--sanitize (em--decode-header (em--hdr hs "to")))
          (em--sanitize (em--decode-header (em--hdr hs "subject")))
          date
          ;; Include the subject in the body column too, so a bare MATCH
          ;; without a column filter still finds subject hits.
          (string-append (em--decode-header (em--hdr hs "subject")) "\n" body))))

;; Indexing runs in timer-scheduled CHUNKS rather than one blocking loop. Each
;; chunk parses up to `em--index-chunk-size` new messages, then yields via
;; `run-with-timer`: control returns to the editor between chunks, so progress
;; messages flush to *Messages*, the UI stays responsive, and C-g
;; (`email-keyboard-quit`) can cancel it. Each chunk commits its own
;; transaction, so a cancel — or a crash — leaves a valid partial index that a
;; re-run resumes (the skip-existing pass picks up where it stopped).
(define em--index-chunk-size 5)

;; Close out a build: free the db handle + build state and report. Chunks commit
;; their own transactions, so there is nothing to commit here.
(define (em--index-finish note)
  (let ((db (em--st 'index-db)))
    (when (and db (> db 0)) (sqlite-close db)))
  (let ((new (em--st 'index-new)) (total (em--st 'index-total)))
    (em--st! 'indexing #f)
    (em--st! 'index-db #f)
    (em--st! 'index-files '())
    (em--st! 'index-existing (hash))
    (message (string-append "email: indexing " note " — " (number->string new)
                            " new, " (number->string total) " total → "
                            (em--index-db-file)))))

(define (email-index)
  (em--load)
  (cond
    ((em--st 'indexing)
     (message "email: indexing already in progress — C-g cancels it"))
    (else
     (let ((dir (em--index-source-dir)))
       (cond
         ((not (file-directory? (path-join dir "cur")))
          (message (string-append "email: no Maildir at " dir
                                  " — run M-x email-export-maildir first")))
         (else
          (let ((db (em--index-open)))
            (if (not (> db 0))
                (message "email: cannot open index")
                (let* ((existing (em--index-existing db))
                       (files (filter (lambda (f) (em--maildir-id f))
                                      (list-directory (path-join dir "cur")))))
                  (em--st! 'index-db db)
                  (em--st! 'index-files files)
                  (em--st! 'index-existing existing)
                  (em--st! 'index-new 0)
                  (em--st! 'index-total (length files))
                  (em--st! 'indexing 'run)
                  (message (string-append "email: indexing started — "
                                          (number->string (length files))
                                          " messages in " dir))
                  (run-with-timer 0 "em--index-chunk"))))))))))

;; One chunk of the running build — fired by `run-with-timer`, reschedules
;; itself until the file list drains or a cancel is seen. Registered as a
;; command so the timer can dispatch it by name.
(define (em--index-chunk)
  (cond
    ((equal? (em--st 'indexing) 'cancel) (em--index-finish "cancelled"))
    ((null? (em--st 'index-files)) (em--index-finish "finished"))
    (else
     (let ((db (em--st 'index-db))
           (existing (em--st 'index-existing))
           (total (em--st 'index-total)))
       (sqlite-exec db "BEGIN" '())
       (let loop ((fs (em--st 'index-files)) (new (em--st 'index-new)) (k 0))
         (cond
           ((null? fs)
            (sqlite-exec db "COMMIT" '())
            (em--st! 'index-files '())
            (em--st! 'index-new new)
            (em--index-finish "finished"))
           ((>= k em--index-chunk-size)
            (sqlite-exec db "COMMIT" '())
            (em--st! 'index-files fs)
            (em--st! 'index-new new)
            (message (string-append "email: indexing … "
                                    (number->string (- total (length fs)))
                                    "/" (number->string total)))
            (run-with-timer 0 "em--index-chunk"))
           (else
            (let* ((path (car fs)) (id (em--maildir-id path)))
              (if (or (not id) (hash-try-get existing id))
                  (loop (cdr fs) new k)                       ; skip: cheap, doesn't fill the chunk
                  (let* ((date (or (em--cap "^([0-9]+)\\." (basename path)) "0"))
                         (raw (read-file path))
                         (row (em--index-row id date raw)))
                    (sqlite-exec db
                                 "INSERT INTO mail(id,sender,recipients,subject,date,body) VALUES (?1,?2,?3,?4,?5,?6)"
                                 row)
                    (loop (cdr fs) (+ new 1) (+ k 1)))))))))))) ; only new inserts fill the chunk

;; M-x email-index-cancel (and C-g) — stop a running build at the next chunk.
(define (email-index-cancel)
  (if (equal? (em--st 'indexing) 'run)
      (begin (em--st! 'indexing 'cancel)
             (message "email: indexing will stop after the current batch"))
      (message "email: no indexing running")))

;; C-g in an email buffer: stop a running index or export (whichever is live),
;; otherwise behave as the ordinary keyboard-quit.
(define (email-keyboard-quit)
  (cond
    ((equal? (em--st 'indexing) 'run) (email-index-cancel))
    ((equal? (em--st 'exporting) 'run) (email-export-cancel))
    (else (keyboard-quit))))

;; `email-search-local` — a BM25-ranked FTS5 query over the local index. The
;; query is Gmail-ish sugar mapped to FTS5: `from:x` / `subject:y` become
;; column filters, bare words match anywhere. Results pin as a folder view
;; (envelopes for ids not in the db are pulled so they can render).
(define (em--fts-query input)
  ;; Translate "from:foo subject:bar baz" → an FTS5 MATCH string. Column
  ;; filters use FTS5's `col:term` syntax; bare terms are ANDed.
  (em--join
   (map (lambda (tok)
          (cond
            ((em--matches? "^from:" tok)
             (string-append "sender:" (substring tok 5 (string-length tok))))
            ((em--matches? "^to:" tok)
             (string-append "recipients:" (substring tok 3 (string-length tok))))
            ((em--matches? "^subject:" tok)
             (string-append "subject:" (substring tok 8 (string-length tok))))
            (else tok)))
        (filter (lambda (t) (not (equal? t "")))
                (em--split-char (em--trim input) #\space)))
   " "))

(define (email-search-local)
  (if (not (file-exists? (em--index-db-file)))
      (message "email: no local index — run M-x email-index first")
      (read-string
       "Local search: "
       (lambda (input)
         (let ((q (em--trim input)))
           (if (equal? q "")
               (em--goto-inbox)
               (let ((db (sqlite-open (em--index-db-file))))
                 (if (= db 0)
                     (message "email: cannot open index")
                     (let ((ids (map (lambda (r) r)   ; single-column rows = bare ids
                                     (sqlite-query db
                                                   "SELECT id FROM mail WHERE mail MATCH ?1 ORDER BY rank LIMIT 200"
                                                   (list (em--fts-query q))))))
                       (sqlite-close db)
                       (cond
                         ((null? ids) (message (string-append "email: no local matches for " q)))
                         (else
                          ;; Some hits may predate the current db (indexed from
                          ;; the archive); fetch envelopes for the unknown ones
                          ;; so the list can render them.
                          (em--local-search-show ids (string-append "local: " q)))))))))))))

;; Show local-search result ids: render immediately for those already in the
;; db, and (best-effort) pull envelopes for the rest, then pin the view.
(define (em--local-search-show ids label)
  (let ((missing (filter (lambda (id) (not (hash-try-get (em--st 'db) id))) ids)))
    (if (null? missing)
        (begin
          (em--st! 'search-ids ids)
          (em--st! 'folder label)
          (em--list-render 'top)
          (message (string-append "email: " label " — " (number->string (length ids)) " matches")))
        ;; Envelopes for archived-but-unknown hits (from the maildir headers).
        (let ((added (em--index-envelopes-for missing)))
          (em--st! 'search-ids ids)
          (em--st! 'folder label)
          (em--save)
          (em--list-render 'top)
          (message (string-append "email: " label " — " (number->string (length ids))
                                  " matches (" (number->string added) " from archive)"))))))

;; Build minimal envelopes for `ids` straight from their Maildir files, so
;; local hits older than the synced window still show in the list.
(define (em--index-envelopes-for ids)
  (let* ((dir (em--index-source-dir))
         (curdir (path-join dir "cur")))
    (if (not (file-directory? curdir))
        0
        (let* ((files (list-directory curdir))
               (by-id (let loop ((fs files) (h (hash)))
                        (if (null? fs)
                            h
                            (let ((id (em--maildir-id (car fs))))
                              (loop (cdr fs) (if id (hash-insert h id (car fs)) h)))))))
          (let loop ((is ids) (n 0))
            (if (null? is)
                n
                (let ((path (hash-try-get by-id (car is))))
                  (if (or (not path) (hash-try-get (em--st 'db) (car is)))
                      (loop (cdr is) n)
                      (let* ((raw (read-file path))
                             (sp (em--split-raw raw))
                             (hs (em--parse-headers (car sp)))
                             (date (or (string->number (or (em--cap "^([0-9]+)\\." (basename path)) "0")) 0))
                             (e (hash 'id (car is) 'uid 0 'thread ""
                                      'date date
                                      'from (em--sanitize (em--decode-header (em--hdr hs "from")))
                                      'to (em--sanitize (em--decode-header (em--hdr hs "to")))
                                      'subject (em--sanitize (em--decode-header (em--hdr hs "subject")))
                                      'labels '() 'snippet "" 'msgid (em--sanitize (em--hdr hs "message-id")))))
                        (em--st! 'ids (cons (car is) (em--st 'ids)))
                        (em--st! 'db (hash-insert (em--st 'db) (car is) e))
                        (loop (cdr is) (+ n 1)))))))))))

;; ── automatic Maildir mirror ────────────────────────────────────────────────
;; When the "email-maildir" option names a directory, every sync ends by
;; mirroring into it whatever the local db knows that the Maildir doesn't
;; (a manifest diff — self-healing, so a missed run just catches up later).
;; After one full `email-export-maildir` backfill, this is exactly the new
;; arrivals of each sync. mu/notmuch pick them up on their next index run.
(define (em--maildir-auto-dir)
  (let ((v (em--trim (em--acct 'maildir "email-maildir" ""))))
    (if (equal? v "") #f (em--expand-home v))))

;; Mirror specific ids over IMAP (blocking): each is located in All Mail by
;; X-GM-MSGID, fetched raw, and written with its current flags.
(define (em--export-ids-imap todo)
  (let ((conn (em--imap-connect)))
    (if (not conn)
        (em--st! 'exporting #f)
        (if (not (em--imap-select conn em--all-mail))
            (begin (em--imap-logout conn) (em--export-finish "failed (SELECT)"))
            (begin
              (for-each
               (lambda (id)
                 (let ((uid (em--imap-uid-of conn id)))
                   (when uid
                     (let* ((r (em--imap-cmd conn (string-append
                                                   "UID FETCH " (number->string uid)
                                                   " (UID X-GM-MSGID X-GM-LABELS FLAGS INTERNALDATE BODY.PEEK[])")))
                            (fetch (filter (lambda (p) (and (em--matches? " FETCH " (car p))
                                                            (pair? (cdr p))))
                                           (nth r 0))))
                       (when (and (em--imap-ok? r) (pair? fetch))
                         (let ((e (em--parse-fetch (car fetch) #f))
                               (raw (car (cdr (car fetch)))))
                           (when e
                             (when (write-file-hex
                                    (em--maildir-file (em--st 'export-dir)
                                                      (hash-try-get e 'id)
                                                      (hash-try-get e 'date)
                                                      (hash-try-get e 'labels))
                                    (em--latin1->hex raw))
                               (em--export-mark id)
                               (em--st! 'export-count (+ 1 (em--st 'export-count)))))))))))
               todo)
              (em--imap-logout conn)
              (em--export-finish "done"))))))

;; Called at the end of every sync. No option / already exporting → no-op.
(define (em--auto-export)
  (let ((dir (em--maildir-auto-dir)))
    (when (and dir (not (em--st 'exporting)))
      (em--st! 'exporting 'run)
      (em--st! 'export-quiet #t)
      (em--st! 'export-dir dir)
      (em--st! 'export-count 0)
      (em--st! 'export-skip 0)
      (em--export-seen-load dir)
      (let ((todo (filter (lambda (id) (and (hash-try-get (em--st 'db) id)
                                            (not (em--export-seen? id))))
                          (em--st 'ids))))
        (cond
          ((null? todo) (em--st! 'exporting #f))
          ((em--oauth?)
           (em--st! 'export-queue todo)
           (em--st! 'export-token "")
           (em--run-op (lambda () (em--export-next))))
          (else (em--export-ids-imap todo)))))))

;; ── offline mode: eager body cache ──────────────────────────────────────────
;; After an offline sync, download the body of every db message that has no
;; cached file yet — the manifest-diff pattern (same as the auto-Maildir
;; mirror), so a missed run just catches up next time. OAuth: async op chain
;; (editor stays usable). IMAP: one blocking sweep. Attachments stay lazy.
(define (em--cache-bodies)
  (when (and (em--offline?) (not (em--st 'caching)))
    (let ((todo (filter (lambda (id) (not (file-exists? (em--msg-file id))))
                        (em--st 'ids))))
      (when (pair? todo)
        (em--st! 'caching #t)
        (message (string-append "email: downloading " (number->string (length todo))
                                " message bodies for offline …"))
        (if (em--oauth?)
            (begin (em--st! 'cacheq todo)
                   (em--run-op (lambda () (em--cache-next))))
            (begin (em--cache-bodies-imap todo)
                   (em--st! 'caching #f)
                   (message "email: offline cache complete")))))))

(define (em--cache-next)
  (let ((q (em--st 'cacheq)))
    (if (null? q)
        (begin (em--st! 'caching #f)
               (when (equal? (current-buffer) "*email*") (em--list-render 'keep))
               (message "email: offline cache complete")
               (em--op-done))
        (let ((id (car q)))
          (em--st! 'cacheq (cdr q))
          (if (file-exists? (em--msg-file id))
              (em--cache-next)
              (em--api "GET" (string-append "/gmail/v1/users/me/messages/" id "?format=full") ""
                       (lambda (status body)
                         (when (em--2xx? status)
                           (em--store-message-rest id (string->jsexpr body)))
                         (em--cache-next))))))))

(define (em--cache-bodies-imap todo)
  (let ((conn (em--imap-connect)))
    (when conn
      (when (em--imap-select conn em--all-mail)
        (for-each
         (lambda (id)
           (when (not (file-exists? (em--msg-file id)))
             (let ((uid (em--imap-uid-of conn id)))
               (when uid
                 (let* ((r (em--imap-cmd conn (string-append
                                               "UID FETCH " (number->string uid)
                                               " (BODY.PEEK[])")))
                        (fetch (filter (lambda (p) (and (em--matches? " FETCH " (car p))
                                                        (pair? (cdr p))))
                                       (nth r 0))))
                   (when (and (em--imap-ok? r) (pair? fetch))
                     (em--store-message-imap id (car (cdr (car fetch))))))))))
         todo))
      (em--imap-logout conn))))

;; ── outbox (offline / deferred send) ────────────────────────────────────────
;; A queued message is one file in <account>/outbox/, in the compose buffer's
;; own text format with two extra pseudo-headers carrying the threading state
;; that otherwise lives in buffer-locals. Flushing reconstructs and sends each
;; via the active backend, deleting on success and keeping on failure.
(define (em--outbox-dir) (path-join (em--acct-dir) "outbox"))

;; Basenames (NOT full paths) of the queued *.eml files — every caller
;; re-joins with (em--outbox-dir), so returning list-directory's absolute
;; paths would double the directory and every read would miss.
(define (em--outbox-files)
  (let ((dir (em--outbox-dir)))
    (if (file-exists? dir)
        (sort-by (lambda (x) x) string<?
                 (map basename
                      (filter (lambda (f) (em--matches? "\\.eml$" f))
                              (list-directory dir))))
        '())))

(define (em--outbox-count) (length (em--outbox-files)))

;; Serialize the current compose buffer (plus its buffer-local threading) to a
;; new outbox file; returns the path.
(define (em--outbox-save)
  (let* ((stamp (current-time "%Y%m%d%H%M%S"))
         (rnd (substring (random-bytes 4) 0 6))
         (path (path-join (em--outbox-dir) (string-append stamp "." rnd ".eml"))))
    (write-file path
                (string-append
                 "X-Macros-In-Reply-To: " (buffer-local-get "email-in-reply-to") "\n"
                 "X-Macros-Thread-Id: " (buffer-local-get "email-thread-id") "\n"
                 (buffer-string)))
    path))

;; Parse an outbox file → (in-reply-to thread-id compose-text), or #f.
(define (em--outbox-read path)
  (let ((text (read-file path)))
    (if (equal? text "")
        #f
        (let loop ((ls (em--split-char text #\newline))
                   (irt "") (thread "") (rest '()) (in-headers #t))
          (cond
            ((null? ls) (list irt thread (em--join (reverse rest) "\n")))
            ((and in-headers (em--matches? "^X-Macros-In-Reply-To:" (car ls)))
             (loop (cdr ls) (em--trim (or (em--cap "^X-Macros-In-Reply-To:(.*)$" (car ls)) ""))
                   thread rest #t))
            ((and in-headers (em--matches? "^X-Macros-Thread-Id:" (car ls)))
             (loop (cdr ls) irt (em--trim (or (em--cap "^X-Macros-Thread-Id:(.*)$" (car ls)) ""))
                   rest #t))
            (else (loop (cdr ls) irt thread (cons (car ls) rest) #f)))))))

;; Queue the current compose buffer into the outbox (offline send, or a
;; live-send fallback when the network drops). Returns #t on success.
(define (em--queue-to-outbox)
  (let ((path (em--outbox-save)))
    (if (and path (file-exists? path))
        (begin (kill-buffer-named "*email-compose*") #t)
        (begin (message "email: could not write to the outbox") #f))))

;; Best-effort human reason from a Gmail JSON error body, e.g.
;; {"error":{"code":403,"message":"Request had insufficient …"}} → the
;; message. Falls back to a truncated raw body so nothing is ever silent.
(define (em--api-error-msg status body)
  (let ((m (with-handler
            (lambda (e) #f)
            (let ((j (string->jsexpr body)))
              (and (hash? j)
                   (let ((err (hash-try-get j 'error)))
                     (and (hash? err) (em--jstr (hash-try-get err 'message)))))))))
    (cond
      ((and (string? m) (not (equal? m ""))) m)
      ((equal? (em--trim body) "") (string-append "HTTP " (number->string status)))
      (else (let ((b (em--trim body)))
              (string-append "HTTP " (number->string status) ": "
                             (if (> (string-length b) 160) (substring b 0 160) b)))))))

(define (em--flush-done sent failed)
  (when (equal? (current-buffer) "*email-outbox*") (email-outbox))
  (when (equal? (current-buffer) "*email*") (em--list-render 'keep))
  (let ((err (em--st 'flush-last-err)))
    (message (string-append "email: outbox — " (number->string sent) " sent"
                            (if (> failed 0)
                                (string-append ", " (number->string failed) " failed (kept)"
                                               (if (and (string? err) (not (equal? err "")))
                                                   (string-append " — " err) ""))
                                "")))))

;; `email-outbox-flush` — try to send every queued message. REST is an async
;; op chain (advances on each send's callback); IMAP/SMTP is a blocking loop.
;; After a successful sync we clearly have connectivity — send anything
;; queued. Silent when the outbox is empty or we're logged out, so it never
;; clobbers the "sync done" message. This is what empties the offline-mode
;; outbox on the next G.
(define (em--outbox-autoflush)
  (when (and (pair? (em--outbox-files)) (em--logged-in?))
    (email-outbox-flush)))

(define (email-outbox-flush)
  (em--st! 'flush-last-err "")
  (let ((files (em--outbox-files)))
    (cond
      ((null? files) (message "email: outbox is empty"))
      ((not (em--logged-in?)) (message "email: not logged in — press L"))
      ((em--oauth?)
       (message (string-append "email: sending " (number->string (length files)) " queued …"))
       (em--run-op (lambda () (em--flush-next-rest files 0 0))))
      (else
       (message (string-append "email: sending " (number->string (length files)) " queued …"))
       (let loop ((fs files) (sent 0) (failed 0))
         (if (null? fs)
             (em--flush-done sent failed)
             (let* ((path (path-join (em--outbox-dir) (car fs)))
                    (parsed (em--outbox-read path))
                    (p (and parsed (em--parse-compose (nth parsed 2))))
                    (raw (and p (em--mime-message p (nth parsed 0) #f))))
               (cond
                 ((not raw)
                  (em--st! 'flush-last-err "could not build the message (empty/corrupt outbox file)")
                  (loop (cdr fs) sent (+ failed 1)))
                 ((em--smtp-send (em--recipients p) raw)
                  (delete-file path) (loop (cdr fs) (+ sent 1) failed))
                 (else
                  (em--st! 'flush-last-err (string-append "SMTP send failed — " (tls-last-error)))
                  (loop (cdr fs) sent (+ failed 1)))))))))))

;; One REST send in the flush chain; recurse on its callback.
(define (em--flush-next-rest files sent failed)
  (if (null? files)
      (begin (em--flush-done sent failed) (em--op-done))
      (let* ((path (path-join (em--outbox-dir) (car files)))
             (parsed (em--outbox-read path))
             (p (and parsed (em--parse-compose (nth parsed 2))))
             (raw (and p (em--mime-message p (nth parsed 0) #t))))
        (if (not raw)
            (begin (em--st! 'flush-last-err "could not build the message (empty/corrupt outbox file)")
                   (em--flush-next-rest (cdr files) sent (+ failed 1)))
            (em--api "POST" "/gmail/v1/users/me/messages/send"
                     (string-append "{\"raw\":\"" (base64url-encode raw) "\""
                                    (if (equal? (nth parsed 1) "") ""
                                        (string-append ",\"threadId\":\"" (nth parsed 1) "\""))
                                    "}")
                     (lambda (status body)
                       (if (em--2xx? status)
                           (begin (delete-file path)
                                  (em--flush-next-rest (cdr files) (+ sent 1) failed))
                           (begin (em--st! 'flush-last-err (em--api-error-msg status body))
                                  (em--flush-next-rest (cdr files) sent (+ failed 1))))))))))

;; ── outbox buffer ───────────────────────────────────────────────────────────
;; A minimal list of pending messages: enter edits one (loads it back into a
;; compose buffer and removes it from the queue), d deletes, S flushes all.
(define em--outbox-help
  "  enter edit · d delete · S send all · g refresh · q back")

(define (email-outbox)
  (let* ((files (em--outbox-files))
         (rows (map (lambda (f)
                      (let* ((parsed (em--outbox-read (path-join (em--outbox-dir) f)))
                             (p (and parsed (em--parse-compose (nth parsed 2)))))
                        (if p
                            (string-append (em--fit (em--truncate (hash-try-get p 'to) 30) 30)
                                           "  " (hash-try-get p 'subject))
                            "(unreadable)")))
                    files)))
    (em--st! 'outbox-files files)
    (render-buffer "*email-outbox*" "email-outbox-mode"
                   (em--join (append
                              (list (string-append "Outbox — " (number->string (length files))
                                                   " queued  [" (em--account) "]")
                                    em--outbox-help "")
                              rows)
                             "\n")
                   (list (list 0 "keyword") (list 1 "comment")))
    (clear-overlays)
    (goto-line 3)))

(define (em--outbox-at-point)
  (let ((idx (- (buffer-line) 3))
        (files (em--st 'outbox-files)))
    (if (and (>= idx 0) (< idx (length files))) (nth files idx) #f)))

(define (email-outbox-edit)
  (let ((f (em--outbox-at-point)))
    (if (not f)
        (message "email: no message on this line")
        (let* ((path (path-join (em--outbox-dir) f))
               (parsed (em--outbox-read path)))
          (if (not parsed)
              (message "email: unreadable outbox file")
              (begin
                (kill-buffer-named "*email-compose*")
                (append-to-buffer "*email-compose*" (nth parsed 2))
                (set-major-mode "email-compose-mode")
                (buffer-local-set "email-in-reply-to" (nth parsed 0))
                (buffer-local-set "email-thread-id" (nth parsed 1))
                (delete-file path)           ; editing removes it from the queue
                (goto-char 4)
                (message "email: editing queued message — C-c C-c re-queues/sends")))))))

(define (email-outbox-delete)
  (let ((f (em--outbox-at-point)))
    (if (not f)
        (message "email: no message on this line")
        (begin (delete-file (path-join (em--outbox-dir) f))
               (email-outbox)
               (message "email: deleted from outbox")))))

(define (email-outbox-refresh) (email-outbox))
(define (email-outbox-quit) (switch-to-buffer "*scratch*"))

;; ── mode toggle ─────────────────────────────────────────────────────────────
(define (email-toggle-mode)
  (em--st! 'mode (if (em--offline?) 'live 'offline))
  (when (equal? (current-buffer) "*email*") (em--list-render 'keep))
  (message (string-append "email: " (if (em--offline?) "OFFLINE" "live") " mode"
                          (if (em--offline?)
                              " — G downloads bodies, send queues to the outbox"
                              " — bodies load on open, send goes out immediately"))))

;; ── auto-sync timer ─────────────────────────────────────────────────────────
(define (em--arm-timer)
  (let ((mins (string->number (em--acct 'auto-sync-minutes "email-auto-sync-minutes" ""))))
    (when (and mins (> mins 0) (not (em--st 'timer-armed)))
      (em--st! 'timer-armed #t)
      (run-with-timer (* mins 60000) 'email--timer-tick))))

(define (email--timer-tick)
  (em--st! 'timer-armed #f)
  (let ((mins (string->number (em--acct 'auto-sync-minutes "email-auto-sync-minutes" ""))))
    (when (and mins (> mins 0))
      (when (and (em--st 'loaded)
                 (not (em--st 'syncing))
                 (em--logged-in?))
        (email-sync))
      (em--arm-timer))))

;; ── keymaps + registration ──────────────────────────────────────────────────
(define-key "email-list-mode" "enter"   'email-list-open)
;; Deliberately NO mouse-1 binding in the list: a stray click must never
;; open (and mark read) a message — clicking just moves the cursor. The
;; view keeps click-to-follow for links; opening from the list is enter.
(define-key "email-list-mode" "shift-c" 'email-compose)
(define-key "email-list-mode" "shift-r" 'email-list-reply)
(define-key "email-list-mode" "shift-e" 'email-list-reply-all)
(define-key "email-list-mode" "?"       'email-menu)
(define-key "email-list-mode" "shift-a" 'email-list-archive)
(define-key "email-list-mode" "shift-d" 'email-list-trash)
(define-key "email-list-mode" "shift-u" 'email-list-toggle-unread)
(define-key "email-list-mode" "*"       'email-list-toggle-star)
(define-key "email-list-mode" "s"       'email-list-search)
(define-key "email-list-mode" "/"       'email-search-local)
(define-key "email-list-mode" "f"       'email-folders)
(define-key "email-list-mode" "i"       'email-folder-inbox)
(define-key "email-list-mode" "a"       'email-cycle-account)
(define-key "email-list-mode" "g"       'email-list-refresh)
(define-key "email-list-mode" "shift-g" 'email-sync)
(define-key "email-list-mode" "shift-l" 'email-login)
(define-key "email-list-mode" "shift-o" 'email-outbox)
(define-key "email-list-mode" "q"       'email-list-quit)
(define-key "email-list-mode" "ctrl-g"  'email-keyboard-quit)

(define-key "email-view-mode" "q"       'email-view-quit)
(define-key "email-view-mode" "ctrl-g"  'email-keyboard-quit)
(define-key "email-view-mode" "enter"   'email-view-follow)
(define-key "email-view-mode" "mouse-1" 'email-view-follow)
(define-key "email-view-mode" "n"       'email-view-next)
(define-key "email-view-mode" "p"       'email-view-prev)
(define-key "email-view-mode" "shift-r" 'email-view-reply)
(define-key "email-view-mode" "shift-e" 'email-view-reply-all)
(define-key "email-view-mode" "?"       'email-view-menu)
(define-key "email-view-mode" "shift-a" 'email-view-archive)
(define-key "email-view-mode" "shift-d" 'email-view-trash)
(define-key "email-view-mode" "shift-w" 'email-view-save-attachment)
(define-key "email-view-mode" "b"       'email-view-browse)

(define-key "email-compose-mode" "ctrl-c ctrl-c" 'email-compose-send)
(define-key "email-compose-mode" "ctrl-c ctrl-k" 'email-compose-cancel)
(define-key "email-compose-mode" "ctrl-c ctrl-l" 'email-compose-send-later)
(define-key "email-compose-mode" "ctrl-c ctrl-t" 'email-compose-menu)

(define-key "email-outbox-mode" "enter"   'email-outbox-edit)
(define-key "email-outbox-mode" "mouse-1" 'email-outbox-edit)
(define-key "email-outbox-mode" "d"       'email-outbox-delete)
(define-key "email-outbox-mode" "shift-s" 'email-outbox-flush)
(define-key "email-outbox-mode" "g"       'email-outbox-refresh)
(define-key "email-outbox-mode" "q"       'email-outbox-quit)
(define-key "email-compose-mode" "ctrl-c ctrl-a" 'email-compose-attach)
(define-key "email-compose-mode" "ctrl-c ctrl-b" 'email-compose-toggle-bcc)

;; Motion + scrolling: a "special" read-only buffer bypasses the global evil
;; keymaps, so movement is bound per-mode (the feeds/web-reader arrangement).
(for-each
 (lambda (mode)
   (define-key mode "down"   'next-line)
   (define-key mode "up"     'previous-line)
   (define-key mode "left"   'backward-char)
   (define-key mode "right"  'forward-char)
   (define-key mode "ctrl-n" 'next-line)
   (define-key mode "ctrl-p" 'previous-line)
   (define-key mode "ctrl-v" 'evil-scroll-down)
   (define-key mode "meta-v" 'evil-scroll-up)
   (define-key mode "ctrl-d" 'evil-scroll-down)
   (define-key mode "ctrl-u" 'evil-scroll-up)
   (define-key mode "space"  'evil-scroll-down)
   (define-key mode "home"   'beginning-of-buffer)
   (define-key mode "end"    'end-of-buffer))
 (list "email-list-mode" "email-view-mode" "email-outbox-mode"))

;; Modal (evil + helix) overlays: vim motion plus the mode's own keys.
(for-each
 (lambda (prefix)
   (let ((km (string-append prefix "email-list-mode")))
     (define-key km "j"       'next-line)
     (define-key km "k"       'previous-line)
     (define-key km "ctrl-d"  'evil-scroll-down)
     (define-key km "ctrl-u"  'evil-scroll-up)
     (define-key km "g g"     'evil-goto-first-line)
     (define-key km "shift-g" 'email-sync)
     (define-key km "g r"     'email-list-refresh))
   (let ((km (string-append prefix "email-view-mode")))
     (define-key km "j"       'next-line)
     (define-key km "k"       'previous-line)
     (define-key km "ctrl-d"  'evil-scroll-down)
     (define-key km "ctrl-u"  'evil-scroll-up)
     (define-key km "g g"     'evil-goto-first-line)
     (define-key km "shift-g" 'evil-goto-last-line))
   (let ((km (string-append prefix "email-outbox-mode")))
     (define-key km "j"       'next-line)
     (define-key km "k"       'previous-line)
     (define-key km "g g"     'evil-goto-first-line)
     (define-key km "shift-g" 'evil-goto-last-line)))
 (list "evil-normal:" "helix-normal:"))

(define-key "fundamental" "ctrl-c m" 'email)

(register-command "email")
(register-command "email-sync")
(register-command "email-login")
(register-command "email-compose")
(register-command "email-compose-send")
(register-command "email-compose-cancel")
(register-command "email-compose-attach")
(register-command "email-compose-toggle-bcc")
(register-command "email-view-follow")
(register-command "email-view-menu")
(register-command "email-view-toggle-unread")
(register-command "email-view-git-am")
(register-command "email-view-git-am-3way")
(register-command "email-view-git-am-abort")
(register-command "email-view-save-patch")
(register-command "email-compose-menu")
(register-command "email-compose-send-later")
(register-command "email-export-maildir")
(register-command "email-export-cancel")
(register-command "email-index")
(register-command "em--index-chunk")
(register-command "email-index-cancel")
(register-command "email-keyboard-quit")
(register-command "email-search-local")
(register-command "email-list-open")
(register-command "email-list-reply")
(register-command "email-list-reply-all")
(register-command "email-menu")
(register-command "email-list-archive")
(register-command "email-list-trash")
(register-command "email-list-toggle-unread")
(register-command "email-list-toggle-star")
(register-command "email-list-search")
(register-command "email-folders")
(register-command "email-folder-inbox")
(register-command "email-folder-unread")
(register-command "email-folder-starred")
(register-command "email-folder-sent")
(register-command "email-folder-all")
(register-command "email-folder-trash")
(register-command "email-switch-account")
(register-command "email-add-account")
(register-command "email-reload-authinfo")
(register-command "email-cycle-account")
(register-command "email-list-refresh")
(register-command "email-list-quit")
(register-command "email-outbox")
(register-command "email-outbox-flush")
(register-command "email-outbox-edit")
(register-command "email-outbox-delete")
(register-command "email-outbox-refresh")
(register-command "email-outbox-quit")
(register-command "email-toggle-mode")
(register-command "email-view-quit")
(register-command "email-view-next")
(register-command "email-view-prev")
(register-command "email-view-reply")
(register-command "email-view-reply-all")
(register-command "email-view-archive")
(register-command "email-view-trash")
(register-command "email-view-save-attachment")
(register-command "email-view-browse")
