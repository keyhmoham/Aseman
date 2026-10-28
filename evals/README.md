# Evals

Labelled sets that measure the agents' judgement, and their results. Run them
from `services/`:

```bash
go run ./cmd/evals triage -rules-only -out ../evals/triage/results-rules-only.md
```

```bash
EVAL_API_KEY=sk-... EVAL_MODEL=gpt-5.6-terra go run ./cmd/evals triage -out ../evals/triage/results-gpt-5.6-terra.md
```

```bash
EVAL_API_KEY=sk-... EVAL_MODEL=gpt-5.6-terra go run ./cmd/evals reply-chips -out ../evals/reply-chips/results.md
```

Any OpenAI-compatible endpoint works: set `EVAL_BASE_URL` (default
`https://api.openai.com/v1`). The rules-only triage run needs no model and
runs in CI (`cmd/evals/evals_test.go`): the rules may only ever say "can
wait", and on the labelled set they are never wrong.

| Set | What it measures |
| --- | --- |
| [`triage/emails.jsonl`](triage/emails.jsonl) | 60 invented emails to a bike shop (25 need the owner, 35 can wait), each with the reason a person would give. Precision and recall for "needs you", accuracy, how many the rules settle with no model call, and every disagreement. |
| [`reply-chips/cases.jsonl`](reply-chips/cases.jsonl) | 20 agent answers, labelled whether they ask the person to choose and which replies would answer them. Whether replies are offered exactly when they should be, and whether they answer the question. |

The model results are written by whoever runs them with a key; commit them
beside the set with the model in the file name.
