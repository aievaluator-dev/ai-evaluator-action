# ⚡ AI Evaluator — GitHub Action

**Automated LLM quality gates for your CI/CD pipeline.**  
**LLM-as-a-Judge · G-Eval · Faithfulness · Hallucination Detection**

[www.aievaluator.dev](https://www.aievaluator.dev)

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-AI%20Evaluator-green?logo=github)](https://github.com/marketplace/actions/ai-evaluator)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Automatically evaluate your LLM agent's quality on every PR:
- ✅ **Quality gate**: blocks merge if score drops below threshold
- ✅ **PR comments**: posts results with per-query breakdown table
- ✅ **JSON dataset** or **inline test cases**
- ✅ **Custom evaluators**: define your own LLM-as-a-Judge metrics
- ✅ Plan limit enforcement

---

## Quickstart

```yaml
# .github/workflows/evaluate.yml
name: AI Quality Gate
on: [pull_request]

jobs:
  evaluate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aievaluator-dev/ai-evaluator-action@v1
        id: eval
        with:
          api-key: ${{ secrets.AI_EVALUATOR_API_KEY }}
          agent-url: https://staging.my-agent.com/chat
          dataset: ./evals/regression.json
          metrics: g_eval,faithfulness
          min-score: 0.80

      - name: Deploy
        if: steps.eval.outputs.passed == 'true'
        run: ./deploy.sh
```

---

## Inputs

| Input | Required | Default | Description |
|-------|:--------:|---------|-------------|
| `api-key` | ✅ | — | AI Evaluator API key ([dashboard](https://www.aievaluator.dev/settings)) |
| `agent-url` | ✅ | — | Your agent's HTTP endpoint URL |
| `agent-format` | | `openai` | `openai`, `claude`, or `custom` |
| `agent-custom-template` | | — | JSON template (only for `format: custom`) |
| `metrics` | | `g_eval,faithfulness` | Comma-separated metric names. Use UUIDs for custom evaluators |
| `custom-evaluators` | | `[]` | Inline custom evaluators as JSON array `[{name, prompt, threshold}]` |
| `min-score` | | `0.0` | Minimum overall score (0–1). Job fails if lower |
| `dataset` | | — | Path to JSON file (mutually exclusive with `rows`) |
| `rows` | | — | Inline JSON array `[{input, expected_output}]` (mutually exclusive with `dataset`) |
| `mode` | | `sync` | `sync` (wait for results) or `async` (poll) |
| `timeout` | | `300` | Max seconds to wait (async mode only) |
| `engine-url` | | `https://api.aievaluator.dev` | Engine API base URL |
| `comment` | | `true` | Post evaluation results as a PR comment |
| `fail-on-limit` | | `false` | Fail the job if plan limits are exceeded |

> ⚠️ Exactly one of `dataset` or `rows` is required.

## Outputs

| Output | Description |
|--------|-------------|
| `evaluation-id` | UUID of the evaluation |
| `overall-score` | Overall score (0–1) |
| `passed` | `true` if score ≥ min-score |
| `results-json` | Full evaluation results as JSON |
| `total-rows` | Number of queries evaluated |
| `input-tokens` | Total input tokens consumed |
| `output-tokens` | Total output tokens consumed |
| `failed-queries` | Number of queries that did not pass |

---

## Agent Authentication

If your agent requires a Bearer token or API key:

```yaml
- uses: aievaluator-dev/ai-evaluator-action@v1
  with:
    api-key: ${{ secrets.AI_EVALUATOR_API_KEY }}
    agent-url: ${{ vars.STAGING_AGENT_URL }}
    agent-auth-type: bearer
    agent-auth-token: ${{ secrets.AGENT_BEARER_TOKEN }}
    dataset: ./evals/regression.json
```

For API key auth:

```yaml
- uses: aievaluator-dev/ai-evaluator-action@v1
  with:
    api-key: ${{ secrets.AI_EVALUATOR_API_KEY }}
    agent-url: ${{ vars.STAGING_AGENT_URL }}
    agent-auth-type: api_key
    agent-auth-header: X-API-Key
    agent-auth-token: ${{ secrets.AGENT_API_KEY }}
```

Supported auth types: `none` (default), `api_key`, `bearer`. When `agent-auth-header` is empty, the action auto-detects the correct header (`Authorization` for Bearer, `X-API-Key` for API key).

## Custom Evaluators

Define your own metrics inline — no need to create them in the UI first:

```yaml
- uses: aievaluator-dev/ai-evaluator-action@v1
  with:
    api-key: ${{ secrets.AI_EVALUATOR_API_KEY }}
    agent-url: https://my-agent.com/chat
    dataset: ./evals/test.json
    metrics: g_eval,faithfulness
    custom-evaluators: |
      [
        {"name": "legal-accuracy", "prompt": "You are a legal evaluator. Score 0-1 on correctness.", "threshold": 0.80},
        {"name": "tone-check", "prompt": "Evaluate the response tone. Score 0-1.", "threshold": 0.70}
      ]
```

The engine hashes `prompt + threshold` and auto-creates versions. If the same definition already exists, the UUID is reused (idempotent). If it changes, a new version is created.

---

## Dataset format

### JSON
```json
[
  {"input": "What is 2+2?", "expected_output": "4"},
  {"input": "Capital of France?", "expected_output": "Paris"}
]
```

---

## Supported metrics

| Metric | Description | Best for |
|--------|-------------|----------|
| `g_eval` | General LLM-as-a-Judge evaluation | Overall quality |
| `faithfulness` | Factual accuracy vs context | RAG agents |
| `hallucination` | Detects fabricated information | Safety-critical |
| `bias` | Identifies biased outputs | Fairness |
| `answer_relevancy` | How well the answer addresses the query | Chatbots |

---

## How it works

```
GitHub Runner                AI Evaluator Engine         Your Agent
─────────────                ───────────────────         ──────────
  │                                │                        │
  ├─ POST /evaluations/sync ──────▶│                        │
  │  (dataset + agent config)       │                        │
  │                                ├─ POST query ──────────▶│
  │                                │◀── response ────────────┤
  │                                ├─ evaluate with LLM judge│
  │◀── result JSON ────────────────┤                        │
  │  {overall_score, passed, ...}   │                        │
  │                                │                        │
  ├─ score ≥ min-score?            │                        │
  │  ✅ exit 0 → deploy            │                        │
  │  ❌ exit 1 → block             │                        │
  │                                │                        │
  ├─ gh pr comment ───────────────▶│ (score table)           │
```

---

## Getting an API key

1. Go to [AI Evaluator](https://www.aievaluator.dev)
2. Login → Settings → API Keys
3. Create a new key → copy it
4. In GitHub: **Settings → Secrets and variables → Actions → New repository secret** → `AI_EVALUATOR_API_KEY`

---

## Plans

| Plan | Evals/cycle | Best for |
|------|:-----------:|----------|
| Free | 100 | Development & testing |
| Pro | 150 | Team CI/CD |
| Enterprise | Unlimited | Heavy usage |

The action checks your plan limits before running and warns if you're close. Set `fail-on-limit: true` to block the pipeline instead.

---

## Support

📧 [support@aievaluator.dev](mailto:support@aievaluator.dev)

---

## License

MIT
