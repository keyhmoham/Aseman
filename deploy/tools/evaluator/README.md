# Traders evaluator tool

Scores traders' reliability from their CoinMarketCap community posts and
keeps the **Traders leaderboard** the Tradera app shows.

| | |
|---|---|
| **Backend** | managed **docker** — [`Dockerfile`](Dockerfile), an MCP server ([`evaluator/server.py`](evaluator/server.py)) with a headless Chromium, run by the node as a Nomad service. |
| **Frontend** | generative — an admin console ([`frontend-skill.md`](frontend-skill.md)): the leaderboard, adding traders, re-evaluating, the worker's state. |
| **Lives in** | the platform's **admins space**, run as the node administrator (`node-a`). |
| **Database** | the tool bot's own KV store (`bots.kv_*` through the tool gateway). |

## How it works

For each trader on its list (each one a CoinMarketCap community profile
link), the evaluator's background worker:

1. **crawls the profile with a browser** ([`evaluator/crawler.py`](evaluator/crawler.py)) —
   davinci-agent's `browser_automation` Playwright logic, logged in with
   decifi's **browser session mechanism**: a Playwright `storage_state`
   (cookies + localStorage, from decifi's `capture_cmc_session.py`) or a
   cookie jar (`cmc_cookiejar.json` from decifi's `refresh.sh`). It reads the
   trader's own posts from the community API responses the page loads
   (text, time, tagged coins, engagement), and the profile's followers;
2. **measures the posts against market data** ([`evaluator/market.py`](evaluator/market.py)):
   daily OHLCV of every coin they name (Binance public market data), the
   1/3/7/30-day returns after each post, the 7-day maximum excursions both
   ways, ATR and the prior trend, and the Fear & Greed index on the day;
3. **analyses them with decifi's prompt** ([`evaluator/prompt.py`](evaluator/prompt.py)) —
   the analyst-reliability objective of decifi's trader backend (and of
   davinci-agent's `scripts/crypto_predictions_test.py`), verbatim, with the
   crawled posts and market data attached. The admins space's lead agent
   (the built-in `tradera` agent) answers by default, on the platform's
   models and billing; an OpenAI-compatible endpoint can be configured
   instead;
4. **stores the STEP 15 Final JSON** with its headline scores (overall,
   technical, fundamental, historical accuracy, consistency, risk management,
   timing, confidence), the STEP 13 rating and a score history in KV.

## Each trader's Tradera account

Adding a trader makes them an ordinary **user account on this platform**
([`evaluator/platform.py`](evaluator/platform.py)): their CoinMarketCap
handle as the username (or one the admin picks with `username`), and a random
20-character password the evaluator keeps in its KV store. Admins read it with
`trader_credentials` (or **Credentials** in the app's trader report). The
account is made by the node's `users.account_create`, which a tool may call
only from the platform admins space while working for a platform
administrator; it is active and verified at once, never an administrator, and
tagged as the evaluator's, so the evaluator can later delete it and no other.
A taken username fails the add: add the trader again with another `username`.

In **every evaluation round** the evaluator signs in as the trader through the
node's public API (`auth.login`, then Ed25519-signed requests like the app's)
and **upserts their 10 latest posts** — the ones that round reads: new ones
are published, an edited one is replaced, one deleted on the platform is
published again, unchanged ones are left alone. Each post keeps its coins as
tags and ends with its CoinMarketCap date and link. The outcome is the
report's `posts_sync`.

**Removing a trader** (`trader_remove`, or **Remove trader** in the app)
deletes their scores, the posts the evaluator published as them and their
account; `keep_account: true` keeps the account and its posts and returns the
credentials one last time.

Each trader is evaluated again every `interval_hours` (12 by default). The
admins space's **"evaluator heartbeat"** routine calls the `tick` microtool
every 10 minutes: a backend acts on the platform only with the scope a call
gave it (15 minutes), and the heartbeat keeps one fresh for the worker.

KV keys: `evaluator/config`, `evaluator/session`, `evaluator/traders` (the
handles in order) and `evaluator/trader/<handle>` (one trader's record,
with their account's credentials and the posts published for them). Only
the admin microtools return a password; `leaderboard` and `trader_get`
show the account's username alone.

## Microtools

| | who | |
|---|---|---|
| `leaderboard {board?, limit?}` | anyone | ranked traders; `board`: overall, technical, fundamental, accuracy, consistency, risk, timing |
| `trader_get {handle}` | anyone | a trader's full report and history |
| `traders_list`, `status` | anyone | the list with statuses; the worker, settings and session (no secrets) |
| `trader_add {profile_link, name?, username?}` | admins space | add a trader by link: makes their Tradera account, evaluates them right away |
| `trader_remove {handle, keep_account?}` | admins space | remove a trader, their scores, posts and account (`keep_account` keeps the last two) |
| `trader_credentials {handle}` | admins space | the trader's Tradera username, account id and password |
| `evaluate_now {handle?}` | admins space | queue one trader, or all |
| `configure {…}` | admins space | `interval_hours`, `max_posts`, `proxy`, `agent_bot`, `llm_base_url`, `llm_api_key`, `llm_model` |
| `set_session {storage_state \| cookies}` | admins space | the logged-in CoinMarketCap session |
| `tick` | admins space | the routine's heartbeat |

Admin microtools are refused unless called from a space the tool was added
to (it is only in the admins space). The app reads the leaderboard through the
node's **`tools.traders_leaderboard`** and **`tools.trader_profile`**, which
any signed-in person may call: the node finds the admins space's tool named
`evaluator` and asks only `leaderboard` / `trader_get` for them, outside any
space.

## Deploy

On the docker host of the node (its Nomad runs the image from the local
docker daemon):

```bash
deploy/tools/evaluator/upsert.sh \
  --password "$TRADERA_ADMIN_PASSWORD" \
  --cmc-session ../decifi/decima-davinci-flow/cmc_storage_state.json \
  --trader https://coinmarketcap.com/community/profile/daniel_crypto365/
```

It signs in as `node-a`, upserts the **"admins space"** project, makes it the
platform's admins space, builds `tradera/evaluator-tool:v1`, upserts the
`evaluator` tool (a re-run restarts it on the new build and keeps its
traders and scores), adds it to the space, upserts the heartbeat routine,
and uploads the session and traders. `--help` lists every option
(`--llm-base-url/--llm-api-key/--llm-model`, `--proxy`, `--eval-hours`,
`--image … --no-build` for a registry image, `--dry-run`).

Use a fixed image tag, never `:latest` or none: Nomad's docker driver always
pulls those from a registry, so a local build of one never starts (the node
then reports *the tool's backend is not answering … lookup tool-…*). The
script refuses such an `--image`, and replaces an `evaluator` created with
one (it never ran, so it holds no traders or scores). Re-running it rebuilds
the same tag and restarts the tool on the new build.

Admins add more traders later from the tool's console on the admins space
desk, by asking the space's agent ("add this trader: <link>"), or with:

```bash
tradera call --json '{"bot":"<evaluator>","space":"<admins space>","function":"trader_add",
  "payload":{"profile_link":"https://coinmarketcap.com/community/profile/<handle>/"}}' tools.invoke
```

The CoinMarketCap session expires: when traders fail with "account doesn't
exist", capture a fresh one with decifi's `capture_cmc_session.py` and run
the script again with `--cmc-session`.

## Test

```bash
cd deploy/tools/evaluator && python3 -m unittest discover -s tests   # the service, MCP over HTTP, parsing, market maths
deploy/tools/evaluator/test/upsert.test.sh                         # the upsert decisions, with a stub CLI
```
