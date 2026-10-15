# Traders evaluator — admin console

The admins space's console for the traders evaluator: the leaderboard it
keeps, adding traders by their CoinMarketCap profile link, acting on one
trader, and the worker's state. It must read cleanly and work fully on a
phone (≈360 px wide) and on a desktop (≈1400 px), with no overflow, clipped
text or dead buttons on either.

## Data

- Fill `/board` with the `leaderboard` microtool for `{"board": "overall"}`
  and `/status` with the `status` microtool for `{}`. Everything shown comes
  from them (and from the actions below); never invent a value or a
  placeholder number.
- Show a value with a binding (`{"path": "/board/total"}`; inside a List or
  Table item, relative: `{"path": "name"}`). Text that mixes words and values
  is a `formatString` call, e.g. `{"call": "formatString", "args": {"value":
  "${/board/evaluated} of ${/board/total} evaluated"}, "returnType": "string"}`.
  A plain string is shown as written, so never put `${…}` or `{{…}}` in one.
- `/board` holds `board`, `total`, `evaluated`, `updated_at` and `traders`, a
  list of `rank`, `handle`, `name`, `profile_link`, `followers`,
  `posts_analyzed`, `status` (queued, running, done or error), `rating`,
  `last_evaluated_at`, `last_error`, `platform_account` (`handle`, `id`) and
  `scores` (`overall_score`, `technical_score`, `fundamental_score`,
  `historical_accuracy`, `consistency`, `risk_management`, `timing`,
  `confidence`, numbers 0-100).
- `/status` holds `running` (a handle or null), `queue` (handles),
  `last_cycle`, `config` (`interval_hours`, `max_posts`, `proxy`,
  `llm_model`) and `session` (`present`, `logged_in`, `cookies`,
  `authorization_expires`).
- Inputs live under `/form`; the trader tapped in the leaderboard is written
  to `/selected` (the Table's `selection`); credentials fetched for them land
  in `/credentials`.

## Layout

One root Column, blocks top to bottom in this order, each block one Card or
Section. Nothing is placed side by side with a plain Row unless it is at most
two short items (a title and one button); everything that should sit side by
side on a desktop and stack on a phone goes in a Grid (it reflows by
`minColumnWidth`) or a Wrap.

1. **Header** — a Row (justify spaceBetween, align center): a Column
   (weight 1) with "Traders evaluator" (h4) and a caption (formatString
   "${/board/evaluated} of ${/board/total} traders evaluated · updated
   ${/board/updated_at}"); a borderless Button "Refresh" sending `refresh`.
2. **Overview** — a Grid (minColumnWidth 150, gap 12) of four Stat tiles:
   "Traders" (`/board/total`, integer), "Evaluated" (`/board/evaluated`,
   integer), "Running now" (`/status/running`), "CMC signed in"
   (`/status/session/logged_in`). Two columns on a phone, four on a desktop.
3. **Add a trader** — a Card holding a Column:
   - a Grid (minColumnWidth 260, gap 12) with a TextField "CoinMarketCap
     profile link" bound to `/form/link` and a TextField "Username
     (optional)" bound to `/form/username` — side by side on a desktop,
     stacked on a phone;
   - a caption: "e.g. https://coinmarketcap.com/community/profile/daniel_crypto365/
     — each trader gets a Tradera account (their CoinMarketCap handle unless
     you pick a username) where their latest posts are published.";
   - a Row (justify end) with a primary Button "Add trader" sending `add`.
4. **Leaderboard** — a Section titled "Leaderboard", subtitle (formatString
   "Ranked by ${/board/board}"), holding:
   - a Wrap (spacing 8, runSpacing 8) of borderless Buttons "Overall",
     "Technical", "Fundamental", "Accuracy", "Consistency", "Risk", "Timing",
     sending `overall`, `technical`, `fundamental`, `accuracy`,
     `consistency`, `risk`, `timing` — it wraps onto a second line on a
     phone instead of overflowing;
   - a Table over `/board/traders`, dense, search true, pageSize 20,
     `selection` `{"path": "/selected"}`, columns: `rank` "#" (integer),
     `name` "Trader", `rating` "Rating" (badge), `scores/overall_score`
     "Overall" (progress, max 100), `scores/technical_score` "Technical",
     `scores/fundamental_score` "Fundamental", `scores/confidence`
     "Confidence" (these three number:1, end-aligned), `status` "Status"
     (badge), `last_evaluated_at` "Evaluated" (datetime). Keep it to these
     columns: the Table scrolls sideways on a phone, so do not add more.
   - a caption: "Tap a trader to see their scores and act on them."
5. **Selected trader** — a Section titled "Selected trader", subtitle
   (formatString "${/selected/name} · @${/selected/handle}"), holding a Grid
   (minColumnWidth 280, gap 16) of two Cards:
   - **Scores** — a KeyValue with items "Overall", "Technical",
     "Fundamental", "Accuracy", "Consistency", "Risk management", "Timing",
     "Confidence" bound to `/selected/scores/…` (format number:1), then
     "Status" (`/selected/status`, badge), "Posts analyzed"
     (`/selected/posts_analyzed`), "Followers" (`/selected/followers`,
     compact), "Last error" (`/selected/last_error`).
   - **Account and actions** — a Column: a KeyValue with "Tradera account"
     (`/selected/platform_account/handle`), "Profile"
     (`/selected/profile_link`); a Wrap (spacing 8) of Buttons, each with
     context `{"handle": {"path": "/selected/handle"}}`: primary
     "Re-evaluate" (event `evaluate`), borderless "Show credentials" (event
     `credentials`), borderless "Delete trader" (event `remove`); then a
     KeyValue with "Username" (`/credentials/username`), "Password"
     (`/credentials/password`), "Account id" (`/credentials/account_id`) and
     a caption "Shown after Show credentials. The evaluator signs in with
     this account to publish the trader's posts. Delete also removes this
     account and the posts the evaluator published."
6. **Worker** — a Section titled "Worker", trailing a borderless Button
   "Refresh" sending `status`, holding a Grid (minColumnWidth 150, gap 12) of
   Stat tiles: "Running" (`/status/running`), "Queue" (formatString
   "${/status/queue}"), "Every (h)" (`/status/config/interval_hours`), "Max
   posts" (`/status/config/max_posts`), "Session expires"
   (`/status/session/authorization_expires`, datetime); then a caption
   (formatString "Last cycle: ${/status/last_cycle/handle}
   ${/status/last_cycle/error}").

## Actions

Each event maps to exactly one microtool call; `reload` re-runs the two data
bindings afterwards (so `/board` returns to the overall board and `/status`
is fresh). Every Button's event name above has an entry here, and nothing
here is unused.

- `refresh`: `leaderboard` with `{"board": {"$data": "/board/board"}}`,
  result at `/board`.
- `status`: `status` with `{}`, result at `/status`.
- `add`: `trader_add` with `{"profile_link": {"$data": "/form/link"},
  "username": {"$data": "/form/username"}}`, result at `/form/added`,
  reload true.
- `overall`, `technical`, `fundamental`, `accuracy`, `consistency`, `risk`,
  `timing`: `leaderboard` with `{"board": "<the event's name>"}`, result at
  `/board`.
- `evaluate`: `evaluate_now` with `{"handle": {"$context": "handle"}}`,
  reload true.
- `credentials`: `trader_credentials` with `{"handle": {"$context":
  "handle"}}`, result at `/credentials`.
- `remove`: `trader_remove` with `{"handle": {"$context": "handle"}}`, result
  at `/selected` (clears the panel of the removed trader), reload true.

## Style

A calm, dense admin view: consistent 12–16 px gaps, one heading level per
block (h4 for the page, Section titles for blocks), captions for help text,
scores as numbers with one decimal, status colors only on Badges for state
(done good, running/queued warning, error critical). No decoration, no
gradients, no fixed widths or heights that would break a phone layout.
