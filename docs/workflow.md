# Use, learn, preserve

## Before a Microsoft administration task

1. Establish task scope, target service/environment and existing authorization.
2. Search the catalogue by purpose/product, including alternative terms when needed.
3. Read the matched runbook, current evidence and limitations. Reuse or improve it;
   if none fits, consult registered references or generate a new implementation.
4. Verify permissions and context for each service actually used. Treat API paging,
   partial errors, throttling and missing data according to the operation's needs.

## After the task

Return generalized code, meaningful regression tests and the validation result to
this repository. Leave client-specific configuration, raw outputs and identities
in approved private storage. A one-off operation need not become a reusable script;
a discovered failure condition or a reference can be the useful artifact instead.

For a new catalogue entry, copy the shape of an existing entry in `catalog.json`:
ID, purpose, areas/tags, path, runbook, read-only/changes-state effect, status,
permissions, local dependencies, tests, source IDs, evidence paths. Dependencies
and tests must include the local files whose behavior affects the recorded claim.
Record external module/runtime versions in the evidence and runbook. Empty lists
are allowed but are not a claim that dependencies have been fully audited.

`effect` describes service-state effects; read-only scripts can still write local
reports or establish sessions. Connection/setup helpers are marked changes-state.
The catalogue does not grant permission to execute either kind.

## Evidence

Use the template command to calculate artifact hashes for the exact checkout:

```bash
python3 tools/toolkit.py evidence-template find-oldusers --scope offline
```

Save the completed JSON under `docs/evidence/` and append its relative path to the
entry's `evidence` list. The template says `pending`; it does not perform a check.
Record date, actual procedure, expectations, observations, runtime and limitations.
For execution records use exact OS/PowerShell/module versions. For review records
state that execution was not performed. Keep documents in English and avoid raw
identifiers in fixtures. Complete the observation fields from evidence, not inference.

Scopes: review / offline / lab / production. Outcomes: pending / passed / failed /
inconclusive. A failed DC query is not evidence that no active accounts exist.

Only the latest completed current lab/production result being passed permits `verified`. Records are ordered by date, then by their position in the evidence list for same-day checks. A later failure or inconclusive result revokes the claim until resolved. The checker compares
all declared artifact hashes, including runbook, test and helper files. Editing code, adding
a dependency or changing a test makes old records historical. Keep the old record,
set status to experimental and append a new record after revalidation. A fresh hash
only establishes that the record refers to those files; it cannot authenticate the
record, guarantee complete dependency declaration, or replace review of its claims.

## Outside code

Register useful upstream repositories in `sources.json` without copying them.
When a task warrants code adoption, record the exact repository, file path, commit
SHA, author, original license text and modification rationale in a provenance note;
link it from the runbook. Preserve per-file attribution and required notices under
`LICENSES/` or beside the imported file. Check files with their own upstream sources.
If reuse permission is unclear, keep a reference and use a different implementation.

The catalogue's source IDs make adopted origins searchable, but presence in
`sources.json` alone is not sufficient provenance for copied code. Review this in PRs.
Mature tools may be dependencies with a versioned runbook instead of copied internals.

Check upstream changes when using an adopted script. Compare the recorded upstream
revision to the new one and to local modifications; port relevant fixes in a PR.
Do not overwrite local code or automatically execute upstream code. No bulk mirror,
automatic update job or additional hosting service is required.

## Integration with an AI workspace

The companion `ms-toolkit` skill supplies task-start search and task-end improvement
routing. Keep authentication in existing service/tenant skills. The toolkit itself
is reusable independently of any agent or workspace. A prompt reminder is advisory;
it cannot guarantee that an agent follows the process. Catalogue checks in CI enforce
record structure; agent review and task-specific tests enforce the actual claim.
