# Microsoft Admin Toolkit

Reusable Microsoft administration scripts, their tests, and the conditions under
which they have actually been checked. Evolved from `m365management`; existing
script paths remain available.

**Start with the task, not with collecting more code.** Search what exists, read
its evidence and limitations, then reuse, improve, or generate what the task needs.
Afterwards, preserve the generalized improvement and the observed result.

## Find a starting point

Requires Python 3.10+; no third-party packages, credentials, or network access.
These commands only read metadata and files. They never execute administration code.

```bash
python3 tools/toolkit.py search "exchange"
python3 tools/toolkit.py search "棚卸し"
python3 tools/toolkit.py search "azure"
python3 tools/toolkit.py validate
```

`catalog.json` lists maintained local scripts. `sources.json` lists external
references, including Sam Erde, PnP, Azure samples and the existing AzureManagement
repository. Registration is not adoption or endorsement of every script.

| Area | Existing code / next-use references |
| --- | --- |
| Identity | [Active Directory](ActiveDirectory/), [Entra ID](EntraID/) |
| Microsoft 365 | [Inventory](All/), [Exchange](Exchange/), [Teams](Teams/) |
| Azure | AzureManagement and Azure official samples in `sources.json` |
| Endpoints, security, other Microsoft products | Add the first actual use case; no empty category scaffolding needed |

PowerShell, CLI scripts, Python, KQL and infrastructure templates can all be
catalogued. Existing PowerShell scripts must be registered; other file types may
be registered using the same metadata format.

## Read evidence before using a script

All inherited scripts currently start as **legacy-unverified**. This does not say
that they have never worked; it says revision-bound execution evidence has not
been recorded here. Existing documentation is not proof of tested permissions or
complete result collection. See [known limitations](docs/known-limitations.md).

- `legacy-unverified`: inherited code without current execution evidence.
- `experimental`: new or changed code awaiting field validation.
- `verified`: a current passed lab/production record exists for all declared artifacts;
  the claim applies only to that record's conditions.
- `deprecated`: read the runbook for the replacement.

An offline test does not establish tenant validation. `validate` checks record
consistency, not the truth of a recorded claim or the correctness of a script.

## Preserve what the next task should know

Read the [contribution workflow](docs/workflow.md). It covers reusable changes,
source attribution, evidence records, and upstream updates. A concrete first
[AD review record](docs/evidence/ad-old-users-review.json) demonstrates scoped,
revision-bound evidence without claiming live-domain validation.

```bash
python3 tools/toolkit.py evidence-template find-oldusers --scope offline
python3 -m unittest discover -s tests -v
```

Run administration code only after checking the target service's authentication,
permissions and existing change-approval rules. Cloud CLI, Graph, Exchange, Teams
and on-premises AD contexts are independent. Keep tenant configuration, customer
outputs and credentials in their existing private stores.
