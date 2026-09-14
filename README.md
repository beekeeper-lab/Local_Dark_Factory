# Local Dark Factory

A lights-out software line running on local models on **Forge** (Framework Desktop, Fedora Server, ~126 GB unified memory). Humans and AI refine requirements into *beans*; the line writes the spec, audits it, builds it task by task, audits the build, writes the implementation-detail document, audits that, and opens the PR. Frontier models build and tune the line — they never run on it.

| File | Role |
| --- | --- |
| `dark-factory-guide.html` | The specification (v5). Open in a browser. |
| `DARK_FACTORY_IMPLEMENTATION_PLAN.md` | The resumable phase ledger — check boxes as work completes. |
| `schemas/*.json` | The seven contracts: bean, task, verdict, event, gate-manifest, risk-policy, repo-config. |

Roles: developer `qwen3.8:27b-q8_0` via Pi · judge `gpt-oss:120b` · deterministic Python controller · human at intake and merge · Opus as outside builder via PRs to this repo.
