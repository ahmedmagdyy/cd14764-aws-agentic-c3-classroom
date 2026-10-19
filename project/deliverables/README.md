# Deliverables

Non-code material for the NovaMart multi-agent customer support submission.

## Required

| File | Content | How it was produced |
|---|---|---|
| [`120.png`](120.png) | `python tests/test_agent.py all` with every check passing and a score of 120/120 | Terminal screenshot |
| [`120.txt`](120.txt) | Full text output of the same test run | Terminal output |
| [`trace1.png`](trace1.png) – [`trace4.png`](trace4.png) | CloudWatch → X-Ray Trace Map: `NovaMart-Orchestrator` connected to InventoryAgent, PolicyAgent, RefundAgent, CommunicationAgent and the `KnowledgeBase:returns/shipping/warranty` nodes | Console screenshots after `python src/agent_orchestrator.py test` |
| [`trace-cmd.txt`](trace-cmd.txt) | Text output of that `test` run: the three graded scenarios and their X-Ray trace ids | Terminal output |

## Stand-out work

### Adversarial guardrail evaluation

| File | Content |
|---|---|
| [`guardrail-eval.md`](guardrail-eval.md) | Report written by `python scripts/guardrail_eval.py`: the live guardrail configuration, 25 cases with expected and actual outcome, fired policies, and the message the customer sees when a request is blocked |
| [`guardrail.png`](guardrail.png) | Terminal screenshot of the same run |

The cases cover legitimate traffic that must pass (the three graded scenarios with their session prefixes, the arithmetic question and its answer, account and policy questions), price haggling and price matching, competitor comparison, legal threats, two prompt-injection attempts, insults, profanity, misconduct, card numbers and SSNs in both directions, and masking of emails and phone numbers in agent replies.

### CloudWatch dashboard

| File | Content |
|---|---|
| [`cloudwatch1.png`](cloudwatch1.png), [`cloudwatch2.png`](cloudwatch2.png) | The `NovaMart-Agents` dashboard created by `python scripts/setup_dashboard.py` |

Widgets: customer requests over time, average and p90 latency per agent, latency per agent over time, calls per agent, parallel policy retrieval latency, guardrail invocations vs interventions, guardrail interventions by policy type, and guardrail latency. The agent widgets are Logs Insights queries over the agent log group; the guardrail widgets use the `AWS/Bedrock/Guardrails` metrics.

## Reproducing the infrastructure

From `starter/`:

```bash
./scripts/deploy_foundation.sh          # CloudFormation stack, seed data, .env, model access check
./scripts/setup_knowledge_bases.sh      # three S3 Vectors Knowledge Bases, synced, IDs written to .env
python src/agent_orchestrator.py deploy # guardrail, AgentCore Runtime, Memory, observability
python scripts/guardrail_eval.py        # adversarial guardrail evaluation
python scripts/setup_dashboard.py       # CloudWatch dashboard
```

Each script supports `--dry-run` (the evaluation supports `--no-report`).
