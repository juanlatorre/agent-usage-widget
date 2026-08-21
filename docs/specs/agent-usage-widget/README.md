# Agent Usage Widget — Child Map

This index is a static delivery map for the parent specification [`../agent-usage-widget.md`](../agent-usage-widget.md). Operational progress belongs to IDD workflow state.

| Child | Outcome | Depends on | Can run in parallel |
|---|---|---|---|
| [01](01-trustworthy-status-app.md) | Companion app renders trustworthy normalized status from persisted snapshots | None | No — foundation |
| [02](02-connect-claude-accounts.md) | Both Claude profile slots connect and report 5-hour/weekly usage | 01 | Yes, with 03–06 |
| [03](03-connect-gpt-personal.md) | GPT Personal connects and reports its weekly window | 01 | Yes, with 02, 04–06 |
| [04](04-connect-opencode-go.md) | OpenCode GO connects and reports 5-hour/weekly/monthly windows | 01 | Yes, with 02–03, 05–06 |
| [05](05-connect-command-code-goat.md) | Command Code GOAT connects and reports 5-hour/weekly windows | 01 | Yes, with 02–04, 06 |
| [06](06-connect-zai-coding-plan.md) | Z.ai Coding Plan connects and reports only its required 5-hour window | 01 | Yes, with 02–05 |
| [07](07-resilient-background-refresh.md) | Resident agent keeps all connected snapshots fresh and honest | 01–06 | No |
| [08](08-native-widget-surfaces.md) | Configurable Small/Medium/Large widgets answer availability at a glance | 07 | No |
| [09](09-direct-release-candidate.md) | The integrated app archives as a signed/notarizable direct release | 02–08 | No |

Cross-cutting invariants and final integrated criteria remain owned by the parent specification.
