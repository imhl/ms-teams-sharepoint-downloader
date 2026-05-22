# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Existing repo labels

Only `wontfix` exists today. The other four (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`) will be created on first use by the `triage` skill — or pre-create them with:

```pwsh
gh label create needs-triage --description "Maintainer needs to evaluate"
gh label create needs-info --description "Waiting on reporter for more info"
gh label create ready-for-agent --description "Fully specified, ready for an AFK agent"
gh label create ready-for-human --description "Needs human implementation"
```
