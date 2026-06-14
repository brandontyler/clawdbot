# Agent Evaluations — Landscape Snapshot (2026-06-13)

> Compiled for the AWS DeepEval-mimic project. 30-day window of community signal
>
> - supplementary deep links. Generated via `/last30days "Agent evaluations"`
>   with web-supplement enrichment (Reddit was 403'd, X keyword search missed the
>   teacher cluster, so most signal here came from web supplements + arXiv).

## TL;DR

1. **The market has split into two tiers.** Commercial: LangSmith ($39/seat),
   [Braintrust](https://braintrust.dev) ($249/mo, $800M valuation after $80M
   Series B). OSS: DeepEval, Arize Phoenix, OpenAI Evals.
2. **Trajectory + step-level eval is the research frontier.** Flat outcome
   scoring masks intermediate failures.
3. **LLM-as-judge has matured past one judge.** Multi-judge DAG ensembles
   break self-preference bias.
4. **Task-adaptive rubrics over fixed rubrics.** `DimensionAwareFilter`-style
   logic prevents one good dimension masking another's failure.
5. **Tool-use makes step-level verification mandatory** — failures are
   irreversible, unlike pure reasoning.
6. **Microsoft Build 2026 dropped an "open trust stack"** — framework-agnostic
   evals + runtime controls + production monitoring.

## The Market (May/June 2026)

### Commercial

- **LangSmith** ($39/seat) — best when you're already on LangChain / LangGraph.
- **Braintrust** ($249/mo, $800M valuation) — strongest hosted experiment UI,
  AI-assisted scorer generation, release gating, hybrid + fully self-hosted
  deploys, free tier 1M spans/mo + 10K eval runs.
  - Founder voice: [@ankrgyl](https://x.com/ankrgyl)
- **Future AGI** — trajectory-first across mixed runtimes.
- **Galileo** — trajectory metrics + outcome metrics framing.
- **Maxim** — production-trace-driven evals.

### Open source

- **[DeepEval](https://github.com/confident-ai/deepeval)** — pytest-style
  component evals, 50+ research-backed metrics, framework-agnostic. Confident
  AI is the hosted backend.
  - Voice: [@deepeval](https://x.com/deepeval)
- **[Arize Phoenix](https://github.com/Arize-ai/phoenix)** — extends ML
  observability to LLMs.
- **[OpenAI Evals](https://github.com/openai/evals)** — reference scaffolding.
- **Ragas** — RAG-specific (retrieval + faithfulness + context precision).
  Account `@ragas_io` is effectively dormant since Jan 2026.

### Sources

- [Future AGI: Agent Evaluation Frameworks 2026](https://futureagi.com/blog/agent-evaluation-frameworks-2026)
- [Digital Applied: AI Agent Eval Frameworks 2026](https://www.digitalapplied.com/blog/ai-agent-eval-frameworks-testing-guide-2026)
- [Latitude: Best AI Agent Evaluation Platforms 2026](https://latitude.so/blog/best-ai-agent-evaluation-platforms-2026-comprehensive-comparison)
- [BigDataBoutique: Frameworks, Metrics, and the Layered System That Ships](https://bigdataboutique.com/blog/llm-evaluation-frameworks-metrics-best-practices)

## The Methodology Frontier

### Trajectory + step-level eval

End-to-end outcome checks miss the intermediate failures that dominate
real-world error budgets. The 2026 working pattern (per Galileo and Future AGI)
is **both**:

- **Outcome metrics** — did the agent finish the task correctly?
- **Trajectory metrics** — every reasoning step, tool call, decision scored
  individually. ReAct-style "what evidence to seek next" steps need their own
  scores.

### DAG-structured step-level eval (the headline academic result)

[**AgentEval (arXiv 2604.23581)**](https://arxiv.org/html/2604.23581v1) — DAG
modeling of step dependencies, validated through a 4-month production pilot.
Ablation showed:

- **+22pp** failure-detection recall (vs flat step-level)
- **+34pp** root-cause accuracy (vs flat step-level)

…with identical judges and rubrics. The dependency graph itself is the win.

### Task-adaptive rubrics

[**AdaRubric (arXiv 2603.21362)**](https://arxiv.org/html/2603.21362v1) —
generates task-specific eval rubrics on the fly from task descriptions.

- Code debugging: needs Correctness + Error Handling.
- Web navigation: needs Goal Alignment + Action Efficiency.
- `DimensionAwareFilter` — provably-necessary condition that prevents
  high-scoring dimensions from masking dimension-level failures. This is the
  bug in naïve aggregate scoring.

### Tool-use specifically

[**Diagnosing Step-Level Process Quality in Tool-Using Agents
(arXiv 2603.14465)**](https://arxiv.org/html/2603.14465) — tool-use failures
induce _irreversible side effects_ (unlike math reasoning where you can
backtrack). Step-level verification is critical, not optional.

## LLM-as-Judge: The Maturing Pattern

### Hamel Husain's school

[Hamel](https://hamel.dev) is the gold-standard practitioner voice. Three
deep-dive posts:

- [Q: How do I evaluate agentic workflows?](https://hamel.dev/blog/posts/evals-faq/how-do-i-evaluate-agentic-workflows.html)
  — introduces **transition failure matrices**: rows = last successful state,
  columns = first-failure state. Makes the failure mode legible.
- [Using LLM-as-a-Judge: A Complete Guide](https://hamel.dev/blog/posts/llm-judge/)
  — domain expert + critique loop, prompt iteration to convergence.
- [Evals Skills for Coding Agents](https://hamel.dev/blog/posts/evals-skills/)
  — case study of 3 engineers building 1M LOC with Codex agents in 5 months.
  Agents queried traces to verify their own work. Documentation tells the
  agent what to do.
- [A Field Guide to Rapidly Improving AI Products](https://hamel.dev/blog/posts/field-guide/)
  — golden dataset, judge calibration, CI gates, 30+ implementations.

### Multi-judge DAG ensembles (real practitioner code)

[**pranavvp16/LLM-sdk-evals PR #13**](https://github.com/pranavvp16/LLM-sdk-evals/pull/13)
— "feat(eval): 3-judge DAG ensemble with DeepEval taxonomies."

The PR replaces a single Claude judge with a **3-judge DAG ensemble**:

- `claude-sonnet-4-6`
- `gpt-5`
- `deepseek-v4-flash`

Specifically to break **self-preference bias** (a single-family judge
preferring outputs from its own family). Adds a 4th eval axis
(`role_violation`) on top of DeepEval's bias / safety / persona-adherence
taxonomies. Includes tight code review iterations on `_coerce_bool()` for
ambiguous judge outputs (returning `None` so the node retries instead of
mis-routing).

This is a worked example of what an AWS DeepEval-mimic might ship.

### Other voices worth following

- [@eugeneyan](https://x.com/eugeneyan) / [eugeneyan.com/writing/evals](https://eugeneyan.com/writing/evals/)
  — "Task-Specific LLM Evals That Do & Don't Work."
- [@sh_reya](https://x.com/sh_reya) — Berkeley PhD, LLM-ops + production
  evals.
- [@lateinteraction](https://x.com/lateinteraction) — Omar Khattab, DSPy
  author, programmatic eval methodology.

## Microsoft Build 2026 — Open Trust Stack

[Build 2026 announcement](https://devblogs.microsoft.com/foundry/build-2026-open-trust-stack-ai-agents/):

> "evaluate an agent against your own policies, place runtime controls at the
> exact checkpoints where it can fail, and monitor its behavior in production.
> You can start today, on any framework, with open source."

Three layers:

1. **Cross-framework evals** (offline, before deploy)
2. **Runtime controls** at failure-prone checkpoints
3. **Production monitoring**

Framework-agnostic and OSS — the big-vendor response to the production-deploy
gap.

## Community Framing

- [@ZhihuFrontier](https://x.com/ZhihuFrontier/status/2056408194801635391):
  "📖 The second half of LLM evaluation has officially begun… 2026 may
  ultimately be remembered as the year Agents moved from demos → production.
  From Auto Research to long-horizon coding, from OS-level operations to
  multi-tool workflows…" (12 likes, May 18 2026)
- [@arxivsanitybot](https://x.com/arxivsanitybot/status/2065857240930644155):
  Surfaced a lifecycle paper modeling four agent co-evolution paths (memory,
  workflow, trajectory, exploration) with three evolution paradigms.
- [Snorkel: Collaborative Gym](https://snorkel.ai/blog/collaborative-gym-a-framework-for-enabling-and-evaluating-human-agent-collaboration/)
  — open framework for evaluating human-agent bidirectional collaboration,
  scores both outcome and process.
- [Nvidia: Mastering Agentic Techniques — AI Agent Evaluation](https://developer.nvidia.com/blog/mastering-agentic-techniques-ai-agent-evaluation/)
  — practical pillars: prioritize task success over accuracy, make tool usage
  a key signal, score reasoning quality and efficiency, integrate transparent
  customizable evaluation from the beginning.

## Implications for the AWS DeepEval-mimic Project

If the goal is "DeepEval but on AWS" or "DeepEval-flavored eval framework for
internal agents," these are the design choices the field has converged on:

| Decision           | What the field is doing                                                 | Why                                   |
| ------------------ | ----------------------------------------------------------------------- | ------------------------------------- |
| Eval shape         | pytest-style component test cases (DeepEval) + trajectory-level scoring | Two complementary granularities       |
| Judge              | Multi-judge ensemble (3 different model families)                       | Single judge has self-preference bias |
| Rubric             | Task-adaptive (AdaRubric) + dimension-aware filtering                   | Prevents dimension masking            |
| Trace structure    | DAG-modeled step dependencies                                           | +22pp recall, +34pp root cause        |
| Metric library     | 50+ research-backed metrics (DeepEval's bar)                            | Component coverage                    |
| Production loop    | Golden dataset → judge calibration → CI gate (Hamel)                    | Catch regressions before users        |
| Deploy story       | Self-host or hybrid (Braintrust pattern)                                | Enterprise compliance                 |
| Framework coupling | None — work with any agent runtime                                      | Avoid LangSmith's LangChain lock-in   |

The **easiest** dimension to differentiate on for a mimic project: native AWS
integration (Bedrock evals, CloudWatch traces, IAM-scoped credentials,
SageMaker for offline eval runs). DeepEval and Braintrust are framework-first;
an AWS-native eval product is unaddressed in the current OSS landscape.

## References (raw research dump)

Full saved raw research file with all 21 engine items + 11 web supplements:
`~/Documents/Last30Days/agent-evaluations-raw-v3.md` (on this EC2 box).

### Primary papers

- [arXiv 2604.23581 — AgentEval (DAG step-level eval)](https://arxiv.org/html/2604.23581v1)
- [arXiv 2603.21362 — AdaRubric (task-adaptive rubrics)](https://arxiv.org/html/2603.21362v1)
- [arXiv 2603.14465 — Step-Level Process Quality in Tool-Using Agents](https://arxiv.org/html/2603.14465)
- [arXiv 2503.16416 — A Survey on Evaluation of LLM-based Agents](https://arxiv.org/html/2503.16416v2)
- [arXiv 2605.23590 — Rubrics as Step-Level Collaborators for ReAct Agents](https://arxiv.org/html/2605.23590v1)
- [arXiv 2605.14865 — Holistic Evaluation and Failure Diagnosis of AI Agents](https://arxiv.org/html/2605.14865v1)
- [arXiv 2604.06132 — Towards Trustworthy Evaluation of Autonomous Agents](https://arxiv.org/html/2604.06132)

### Practitioner blogs

- [Hamel Husain — How do I evaluate agentic workflows?](https://hamel.dev/blog/posts/evals-faq/how-do-i-evaluate-agentic-workflows.html)
- [Hamel Husain — LLM-as-a-Judge Complete Guide](https://hamel.dev/blog/posts/llm-judge/)
- [Hamel Husain — Evals Skills for Coding Agents](https://hamel.dev/blog/posts/evals-skills/)
- [Hamel Husain — Field Guide to Rapidly Improving AI Products](https://hamel.dev/blog/posts/field-guide/)
- [Eugene Yan — Task-Specific LLM Evals](https://eugeneyan.com/writing/evals/)
- [Galileo — Agent Evaluation Framework](https://galileo.ai/blog/agent-evaluation-framework-metrics-rubrics-benchmarks)
- [Nvidia — Mastering Agentic Techniques: AI Agent Evaluation](https://developer.nvidia.com/blog/mastering-agentic-techniques-ai-agent-evaluation/)
- [Microsoft Build 2026 — Open Trust Stack for AI Agents](https://devblogs.microsoft.com/foundry/build-2026-open-trust-stack-ai-agents/)
- [Snorkel — Collaborative Gym](https://snorkel.ai/blog/collaborative-gym-a-framework-for-enabling-and-evaluating-human-agent-collaboration/)
- [Fountain City — Evaluation-Led Agent Development](https://fountaincity.tech/resources/blog/evaluation-led-agent-development/)

### Framework comparisons / market

- [Future AGI — Agent Evaluation Frameworks 2026](https://futureagi.com/blog/agent-evaluation-frameworks-2026)
- [Future AGI — Definitive 2026 Guide](https://futureagi.com/blog/definitive-guide-ai-agent-evaluation-2026/)
- [Future AGI — Best LLM Evaluation Tools 2026](http://futureagi.com/blog/best-llm-evaluation-tools-2026)
- [Future AGI — DeepEval Alternatives 2026](http://futureagi.com/blog/deepeval-alternatives-2026)
- [Digital Applied — AI Agent Eval Frameworks 2026](https://www.digitalapplied.com/blog/ai-agent-eval-frameworks-testing-guide-2026)
- [Digital Applied — Building an AI Agent Evaluation Pipeline](https://www.digitalapplied.com/blog/ai-agent-evaluation-pipeline-2026-testing-methodology)
- [Latitude — Best AI Agent Evaluation Platforms 2026](https://latitude.so/blog/best-ai-agent-evaluation-platforms-2026-comprehensive-comparison)
- [BigDataBoutique — Frameworks, Metrics, and the Layered System](https://bigdataboutique.com/blog/llm-evaluation-frameworks-metrics-best-practices)
- [Confident AI — Top 5 LangSmith Alternatives 2026](https://www.confident-ai.com/blog/top-langsmith-alternatives-and-competitors-compared)
- [Braintrust — Best Self-Hosted AI Evals 2026](https://www.braintrust.dev/articles/best-self-hosted-ai-evals-tools-2026)
- [MLflow — Top 5 Agent Evaluation Tools 2026](http://mlflow.org/top-5-agent-evaluation-frameworks)

### Repos / OSS

- [confident-ai/deepeval](https://github.com/confident-ai/deepeval)
- [Arize-ai/phoenix](https://github.com/Arize-ai/phoenix)
- [openai/evals](https://github.com/openai/evals)
- [pranavvp16/LLM-sdk-evals PR #13 — 3-judge DAG ensemble](https://github.com/pranavvp16/LLM-sdk-evals/pull/13)
- [microsoft/SkillOpt](https://github.com/microsoft/SkillOpt) — text-space optimizer for self-evolving agent skills
