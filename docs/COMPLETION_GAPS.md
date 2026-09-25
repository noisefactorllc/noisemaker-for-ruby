# noisemaker-for-ruby: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Daily review: 2026-09-25. Current inspected source: [`d7942883e2e56486dd6c186486cd794cc3a512a4`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/d7942883e2e56486dd6c186486cd794cc3a512a4).
Full rendered parity remains **unverified**. No release approval or new closure follows from this review.
Current upstream discovery: `bbdeb56c4b75cf33379766c3e87b0f5a18bcbba8`. Published Noisemaker authority: `1.0.179`, source `fca611fd8f91424661d4e531d39313d24ea21134`, 210 effect IDs.
The observations below retain their original source and authority identities; they do not qualify later updates.
Current served kit: `0.1.7`, source `1229d40fd08c3a8dce23173ca187eadcf831820c`. [Retrieved inventory and hashes](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/current-served-inventories.json). Artifact identity does not establish host qualification.

### Earlier source observations

Date: 2026-09-24. Reviewed SHA: [`379aa03df26df8b17f6916535c83328bb0e8eaa3`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/379aa03df26df8b17f6916535c83328bb0e8eaa3).
Local HEAD matched remote main before checks. The operator requested registers for all remaining eligible ports in this run.
This initial register contains bounded evidence. It is not a completed port audit or release approval.
No implementation or parity checkpoint changed. Full audits remain in the rotation.

Offline Ruby CPU renderer with 205 effects and 289 kernels. Ruby 3.2 is the documented floor. Large real-time rendering is outside its practical target. [Contract](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md).

`scripts/oracle-lock.json` pins CPU revision `16c38245c42030c8ee46dc61108791d2fea4bda9` and upstream revision `44bc4ed4ac729bddaa95b083d64bee942ade35da`.
Current upstream at discovery: `c9ee8a049b2b63cd300da67c01ee40baf29dc288`.
Current CPU authority: `f2eb495d70abcb74e3632e7a652a4f83e4f3b11e`.
These authority heads are review targets, not qualification results. No goldens were regenerated.

Served kit `0.1.6` identifies `0140692b2f311d8012cf82e1cf246a35075a9f65`. [Metadata](https://kits.noisedeck.app/ruby/0/deployment-meta.json). Inventory and compatibility metadata were retrieved. Complete artifact bytes were not checked.

The document push triggers Ruby CI. Its release predicate excludes these paths, so no export-kit dispatch is expected.
The containing commit identifies this register's publication revision. The shared run record retains commits, remote hashes, and downstream results.

## 2. Completion claims

| Claim ID | Claim source | Claimed scope | Finding | Evidence |
|---|---|---|---|---|
| CLAIM-001 | [Historical source](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | 205 exact RGBA8 comparisons at 8 by 8, seed 1, time 0.25, with bounded volumes and explicit particle scenes. | partial | Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. |
| CLAIM-002 | [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | Human usability: installation, output, errors, and recovery | unverified | Complete installed workflows were not observed. GAP-002. |
| CLAIM-003 | [Ecosystem reference](https://guides.rubygems.org/make-your-own-gem/) | Ecosystem fit and version support | partial | Source entry points were examined. Installed integration and version qualification remain open. |
| CLAIM-004 | [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | Release readiness | unverified | Metadata and CI do not replace installation of the actual artifact. GAP-003. |
| CLAIM-005 | [Exact-source Actions](https://github.com/noisefactorllc/noisemaker-for-ruby/actions?query=head_sha%3A379aa03df26df8b17f6916535c83328bb0e8eaa3) | Workflow status only | supported | [Ruby CI and export kit](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/35820283884): `success`. |

## 3. Methods and evidence

### Daily review, 2026-09-25

Exact-source CI reports 205 of 205 default CPU cases byte-exact. Its integration test log reports 229 runs, 1,426 assertions, and six skips; standalone variants retain 24 skips. Five current effect IDs and broader parameters, state, platforms, and installed workflows remain unqualified. This is bounded evidence, not full parity. [Raw evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/ruby-ci-36076250675.log).
The review checked source changes, worker evidence, source-bound CI where present, and current served inventories. Full installed-host and platform qualification remains incomplete.

Environment: macOS 26.5, Darwin arm64.
[Source SHA-256 records](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/noisemaker-for-ruby-source-hashes.json) bind these checks to the reviewed revision.
[Raw command evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/ruby-tests.json). [Remote evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/noisemaker-for-ruby-remote.json).

Executed command:

```sh
ruby -Ilib:test test/test_public_api.rb
```

Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. Final exit code: 0.
No image denominator or tolerance follows from a unit-test or generated-file result.
Official reference: [Current RubyGems guide, accessed 2026-09-24](https://guides.rubygems.org/make-your-own-gem/).

| Outcome | Observed scope | Remaining work |
|---|---|---|
| Installation | Instructions and metadata inspected | Install the actual artifact privately. |
| First useful output | Selected checks only | Install the built gem privately. Use effects and describe, render solid, apply lighting, recover from invalid parameters, and remove the gem. |
| Host integration | Not fully exercised | Check parameters, external inputs, state, resize, and cleanup. |
| Errors and recovery | Only the selected checks above | Fail through the installed entry point, correct input, and render again. |
| Distribution | Metadata inspection | Build and install the gem in an isolated GEM_HOME. Check archive installation under Bundler, CLI discovery, notices, and removal. |
| Accessibility | Not observed | Check keyboard, focus, labels, and diagnostics for provided interfaces. |

Headless libraries do not require an editor accessibility test. Their CLI diagnostics and failure handling still require checks.
Host presence does not prove host qualification. This pass made no global installation or user-project changes.

## 4. Known gaps

P1 means false completion or major correctness failure. P2 means coverage or integration uncertainty. P3 means documentation inconsistency.
These entries record missing qualification. They do not infer implementation defects from absent tests.

### GAP-001: current authority and parity qualification

- Status: open. Priority: P2. Category: verification.
- Affected scope: noisemaker-for-ruby.gemspec, scripts/oracle-lock.json, scripts/parity.rb, test/, README.md
- Expected behavior: Reproducible evidence binds each supported claim to the port and authority revisions.
- Observed behavior: Catalog coverage at one small scene per effect is not all-parameter or animation parity. Runtime cost needs workflow-specific acceptance limits.
- Evidence: [Historical source](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) and section 3.
- Next action: Run the locked 205-effect comparator. Extend qualification to nondefault parameters, animation, external textures, and documented Ruby versions.
- Dependencies: Resolve immutable authority inputs. Preserve historical goldens and provenance.
- Acceptance criteria: Report every applicable case, parameter choice, exclusion, error, and tolerance. Do not reduce the denominator to report success.
- Required checks: Existing compiler and rendered parity gates, with raw output and exact source hashes.
- Last verification: 2026-09-24. Full behavior qualification remains unverified.

### GAP-002: installed developer workflow qualification

- Status: open. Priority: P2. Category: usability.
- Affected scope: Public API, examples, supported hosts, errors, recovery, and lifecycle.
- Expected behavior: Developers can install, produce useful output, integrate it, recover from errors, and remove the package.
- Observed behavior: This pass did not exercise the complete installed workflow or supported-version matrix.
- Evidence: [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md), [official reference](https://guides.rubygems.org/make-your-own-gem/), and section 3.
- Next action: Install the built gem privately. Use effects and describe, render solid, apply lighting, recover from invalid parameters, and remove the gem.
- Dependencies: Use an isolated consumer. Identify host, GPU, licensing, and input requirements before execution.
- Acceptance criteria: Retain artifact hashes, steps, meaningful output, error diagnostics, recovery results, and cleanup results.
- Required checks: Test minimum and current supported versions. Check cancellation and file preservation where relevant. Keep unavailable platforms explicit.
- Last verification: 2026-09-24. Source inspection does not close this gap.

### GAP-003: distribution and release qualification

- Status: open. Priority: P2. Category: release.
- Affected scope: Actual artifact, dependencies, notices, version promises, and release evidence.
- Expected behavior: The delivered artifact supports its documented installation and first useful result.
- Observed behavior: Complete artifact reproduction, installation, upgrade, and removal remain unverified.
- Evidence: [Distribution instructions](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md), section 1, and exact-source CI in section 2.
- Next action: Build and install the gem in an isolated GEM_HOME. Check archive installation under Bundler, CLI discovery, notices, and removal.
- Dependencies: Complete GAP-002 for the candidate. Distinguish source CI from downstream publication and native rendering.
- Acceptance criteria: Match artifact bytes to their inventory. Check notices and dependencies. Pass installation, examples, upgrade, and removal.
- Required checks: Inspect exact-source CI jobs and actual render legs. Count skips and errors rather than trusting green summaries.
- Last verification: 2026-09-24. This register does not approve a release.

## 5. Ordered next actions

Current first action: Install the built gem in an isolated GEM_HOME on the declared Ruby floor and current supported Ruby. Execute the documented PNG example, invalid-input recovery, and removal. Reconcile the six integration skips and 24 standalone skips, then extend the current 205-case default gate to the five missing IDs and parameter/state cases.
Subsequent historical actions remain dependent on that evidence. No implementation is authorized by this audit.

1. Resolve authority identities for GAP-001. Retain earlier denominators, goldens, tolerances, and exclusions.
2. Execute the installed workflow for GAP-002. Record meaningful output, failure recovery, versions, and cleanup.
3. Run compiler and rendered parity for GAP-001. Keep structural, numerical, and platform evidence separate.
4. Qualify distribution contents and lifecycle for GAP-003 after the installed workflow passes.
5. Record measured results. Close entries only when their acceptance criteria pass.

Implementation belongs to the separate job. Do not port additional effects or advance the current parity checkpoint through this register.

## 6. Pass history

2026-09-25 daily review at `d7942883e2e56486dd6c186486cd794cc3a512a4`: source freshness and bounded evidence reviewed; open qualification limits retained. [Retained review evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/ruby-ci-36076250675.log). No new closure claimed.

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-24 | `379aa03df26df8b17f6916535c83328bb0e8eaa3` | Created six-section register and README link. No closures. | Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `20260924-remaining-gap-documents`.
[Operational evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents). Creating this register does not advance successful-audit timestamps or the rotation.
