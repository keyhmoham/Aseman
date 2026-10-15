# Traders evaluator — admin console

The admins space's console for the traders evaluator: the leaderboard it
keeps, adding traders by their CoinMarketCap profile link, and the worker's
state.

## Data

- Fill `/board` with the `leaderboard` microtool for `{"board": "overall"}`
  and `/status` with the `status` microtool for `{}`. Everything shown comes
  from them; never invent a value.
- Show a value with a binding (`{"path": "/board/total"}`; inside a List or
  Table item, relative: `{"path": "name"}`). Text that mixes words and values
  is a `formatString` call, e.g. `{"call": "formatString", "args": {"value":
  "${/board/evaluated} of ${/board/total} evaluated"}, "returnType": "string"}`.
  A plain string is shown as written, so never put `${…}` or `{{…}}` in one.
- `/board` holds `board`, `total`, `evaluated`, `updated_at` and `traders`, a
  list of `rank`, `handle`, `name`, `profile_link`, `followers`,
  `posts_analyzed`, `status` (queued, running, done or error), `rating`,
  `last_evaluated_at`, `last_error`, `platform_account` (`handle`, `id`) and `scores` (`overall_score`,
  `technical_score`, `fundamental_score`, `historical_accuracy`,
  `consistency`, `risk_management`, `timing`, `confidence`, numbers 0-100).
- `/status` holds `running` (a handle or null), `queue` (handles),
  `last_cycle`, `config` (`interval_hours`, `max_posts`, `proxy`,
  `llm_model`) and `session` (`present`, `logged_in`, `cookies`,
  `authorization_expires`).

## Layout (top to bottom, in one Column)

1. **Header** — a Row: a Column with "Traders evaluator" (h4) and a caption
   (formatString "${/board/evaluated} of ${/board/total} traders evaluated");
   a borderless Button "Refresh" sending the event `refresh`.
2. **Add a trader** — a Card with a Row: a TextField labelled "CoinMarketCap
   profile link" bound to `/form/link` (weight 2), a TextField labelled
   "Username (optional)" bound to `/form/username` (weight 1) and a primary
   Button "Add" sending the event `add` with context
   `{"link": {"path": "/form/link"}, "username": {"path": "/form/username"}}`.
   Under it a caption: "e.g. https://coinmarketcap.com/community/profile/daniel_crypto365/ —
   each trader gets a Tradera account (their CoinMarketCap handle unless you
   pick a username) where their latest posts are published."
3. **Board** — a Row of borderless Buttons "Overall", "Technical",
   "Fundamental", "Consistency", "Risk", sending the events `overall`,
   `technical`, `fundamental`, `consistency` and `risk`.
4. **Leaderboard** — a Table over `/board/traders`, dense, columns: `rank`
   "#", `name` "Trader", `rating` "Rating", `scores/overall_score` "Overall"
   (type progress, max 100), `scores/technical_score` "Technical" (end-aligned),
   `scores/fundamental_score` "Fundamental" (end-aligned),
   `scores/confidence` "Confidence" (end-aligned), `status` "Status",
   `platform_account/handle` "Account", `last_evaluated_at` "Evaluated".
   Each row has three borderless Buttons, each with context
   `{"handle": {"path": "handle"}}`: "Re-evaluate" (event `evaluate`),
   "Credentials" (event `credentials`) and "Delete" (event `remove`, in the
   error color).
5. **Credentials** — shown only when `/credentials/username` is set: a Card
   titled "Tradera account" with `/credentials/trader` (caption), the
   username (formatString "@${/credentials/username}") and the password
   (`/credentials/password`, monospace, selectable), and a caption "The
   evaluator signs in with this account to publish the trader's posts."
6. **Worker** — a Section titled "Worker" with a Grid (minColumnWidth 160) of
   Stat tiles: "Running" (`/status/running`), "Queue" (formatString
   "${/status/queue}"), "Every (h)" (`/status/config/interval_hours`),
   "CMC session" (`/status/session/logged_in`), "Session expires"
   (`/status/session/authorization_expires`); then `last_cycle` as a caption
   (formatString "Last: ${/status/last_cycle/handle} ${/status/last_cycle/error}").

## Actions

- `refresh`: `leaderboard` with `{"board": {"path": "/board/board"}}`, result
  at `/board`; `status` with `{}`, result at `/status`.
- `add`: `trader_add` with `{"profile_link": {"$context": "link"}, "username":
  {"$context": "username"}}`; then `leaderboard` with `{"board": "overall"}`,
  result at `/board`.
- `credentials`: `trader_credentials` with `{"handle": {"$context": "handle"}}`,
  result at `/credentials`.
- `remove`: `trader_remove` with `{"handle": {"$context": "handle"}}` (it also
  deletes the trader's Tradera account and the posts the evaluator
  published); then `leaderboard` with `{"board": "overall"}`, result at
  `/board`.
- `overall`, `technical`, `fundamental`, `consistency`, `risk`: `leaderboard`
  with `{"board": "<the event's name>"}`, result at `/board`.
- `evaluate`: `evaluate_now` with `{"handle": {"$context": "handle"}}`; then
  `status` with `{}`, result at `/status`.

Keep it a calm, dense admin view: one Card or Section per block, scores as
numbers with one decimal, no decoration.
