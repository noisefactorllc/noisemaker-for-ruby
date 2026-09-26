# noisemaker-for-ruby: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Daily review: 2026-09-25. Current inspected source: [`d7942883e2e56486dd6c186486cd794cc3a512a4`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/d7942883e2e56486dd6c186486cd794cc3a512a4).
Full rendered parity remains **unverified**. No release approval or new closure follows from this review.
Current upstream discovery: `bbdeb56c4b75cf33379766c3e87b0f5a18bcbba8`. Published Noisemaker authority: `1.0.179`, source `fca611fd8f91424661d4e531d39313d24ea21134`, 210 effect IDs.
The observations below retain their original source and authority identities. They do not qualify later updates.
Current served kit: `0.1.7`, source `1229d40fd08c3a8dce23173ca187eadcf831820c`. Retrieved inventory and hashes (retained by the operator review; not committed to this repository). Artifact identity does not establish host qualification.

### Earlier source observations

Date: 2026-09-24. Reviewed SHA: [`379aa03df26df8b17f6916535c83328bb0e8eaa3`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/379aa03df26df8b17f6916535c83328bb0e8eaa3).
Local HEAD matched remote main before checks. The operator requested registers for all remaining eligible ports in this run.
This initial register contains bounded evidence. It is not a completed port audit or release approval.
No implementation or parity checkpoint changed. Full audits remain in the rotation.

Offline Ruby CPU renderer with 205 effects and 289 kernels. Ruby 3.2 is the documented floor. Large real-time rendering is outside its practical target. [Contract](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md).

`scripts/oracle-lock.json` pins CPU revision `16c38245c42030c8ee46dc61108791d2fea4bda9` and upstream revision `44bc4ed4ac729bddaa95b083d64bee942ade35da` in the sections below, which retain their historical measurements. Current lock (updated by sync commits `47a863d`, `0261bcf`, `0984199`) pins CPU revision `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` and upstream revision `2f47612c29045c1b91af94887a8ff20106e980ef` with source digest `182a4a518dcc52586d56470ae04ca17050babccd9fc53889fa2d2cc2ffbd7c5d`; see [evidence summary](evidence/gap-001/parity-evidence-summary.json). Historical pins, goldens, tolerances, and exclusions are preserved; no goldens were regenerated.
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

Exact-source CI reports 205 of 205 default CPU cases byte-exact. Its integration test log reports 229 runs, 1,426 assertions, and six skips. Standalone variants retain 24 skips. Five current effect IDs and broader parameters, state, platforms, and installed workflows remain unqualified. This is bounded evidence, not full parity. Raw CI log for Actions run 36076250675 (retained by the operator review; exact-source Actions are linked above).
The review checked source changes, worker evidence, source-bound CI where present, and current served inventories. Full installed-host and platform qualification remains incomplete.

Environment: macOS 26.5, Darwin arm64.
SHA-256 source-hash records for the 2026-09-26 qualification runs are committed at [parity-evidence-summary.json](evidence/gap-001/parity-evidence-summary.json).
Raw command and remote evidence for the 2026-09-24 register (operator-retained; not committed to this repository).

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
- Affected scope: noisemaker-for-ruby.gemspec, scripts/oracle-lock.json, scripts/parity.rb, scripts/parity-sweep.rb, test/, README.md
- Expected behavior: Reproducible evidence binds each supported claim to the port and authority revisions.
- Observed behavior: Default gate is 205 of 205 effects byte-exact at the pinned authority on Ruby 3.2.8 and 3.4.5. The extended sweep (1625 cases: nondefault parameters, animation, iterated state, alternative seed, 16x16, volumeSize variation; byte-exact tolerance) found 17 differing cases across 13 effects and one Ruby runtime error (synth/testPattern pattern=colorBars). See "GAP-001 qualification runs, 2026-09-26" below and section 3.
- Evidence: [Raw sweep report](evidence/gap-001/parity-sweep-report.json), [evidence summary with source hashes](evidence/gap-001/parity-evidence-summary.json), [raw Ruby 3.2.8 default-gate log](evidence/gap-001/parity-default-ruby-3.2.8.log), [compatibility matrix](COMPATIBILITY.md#3-parity-coverage), and the historical source in section 1.
- Next action: Correct the 13 diverging effects (classicNoisedeck/noise3d, filter/craquelure, filter/median, filter/spookyTicker, mixer/shapeMask, points/dla, render/pointsBillboardRender, render/render3d, render/renderCubemap3d, synth/gradient, synth/mandelbrot, synth/testPattern, synth3d/flythrough3d), then re-run the extended sweep and the required checks.
- Dependencies: Immutable authority inputs are resolved and recorded (current lock pins CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c29045c1b91af94887a8ff20106e980ef` via sync commits `47a863d`, `0261bcf`, `0984199`; historical pins, goldens, and tolerances preserved). Qualification also needs installed-workflow evidence (GAP-002) before release claims.
- Acceptance criteria: Report every applicable case, parameter choice, exclusion, error, and tolerance. Do not reduce the denominator to report success.
- Required checks: Existing compiler and rendered parity gates, with raw output and exact source hashes.
- Last verification: 2026-09-26. Full behavior qualification remains unverified: 13 effects differ from the pinned JavaScript oracle at nondefault settings.

### GAP-001 qualification runs, 2026-09-26

The locked 205-effect comparator ran at the pinned authority `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` (upstream `2f47612c29045c1b91af94887a8ff20106e980ef`, verified clean checkout) against Ruby 3.2.8 and Ruby 3.4.5. All runs were executed on a clean tree at pre-publication HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc` (each run's header records that HEAD with `git_dirty: false`); the published candidate adds only the committed evidence files, which sit outside the harness source-hash globs, so `candidate.source_hashes` in the committed report are identical at that HEAD and at this commit (verified after the final amend). The default gate (size 8, seed 1, time 0.25, one scene per effect) is 205 of 205 effects byte-exact on Ruby 3.2.8 (gate transcript: [parity-default-ruby-3.2.8.log](evidence/gap-001/parity-default-ruby-3.2.8.log) — annotated provenance header lines 1-5 added by the invocation wrapper, followed by parity.rb's raw output and exit status). The extended sweep ([raw report](evidence/gap-001/parity-sweep-report.json), [summary with source hashes](evidence/gap-001/parity-evidence-summary.json)) executed 1625 RGBA8 cases across all 205 effects — default scene, up to 3 nondefault-parameter cases per effect (560 executed, 922 parameters excluded with reasons in the report: 826 capped, 41 without a derivable nondefault value, 55 bound via inputs), animation times 0.0 and 1.0, iterated state at iterationCount 3, seed 7, 16x16 scenes, and volumeSize 8 for volume effects — with byte-exact RGBA8 tolerance and no skipped or tolerated differences. 1607 cases are byte-exact; 17 cases across 13 effects differ (maxdiff 1-255) and one Ruby runtime error was observed (synth/testPattern with pattern=colorBars: "can't convert Array into Float"). These are port defects at nondefault settings, listed per effect in the [compatibility matrix](COMPATIBILITY.md#3-parity-coverage) and the evidence summary. The extended sweep ran on Ruby 3.4.5; the committed report is the output of the committed `scripts/parity-sweep.rb` in `--merge` mode (its header records the full merge invocation; the per-run `command` fields in the shard reports record the bare invocation because an option-parsing bug dropped arguments before the field was written, fixed in the committed harness; each run records its ruby version, HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc`, and `git_dirty: false`; the committed harness hash is in the summary). Exact-source CI for these documents is the publication gate; run ids are cited in the evidence summary and section 2. Full behavior qualification remains open until the 13 diverging effects are corrected and re-swept.

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

Ruby 3.2 reached end of life on 2026-04-01. Ruby lists 3.4 and 4.0 under normal maintenance. Preserve 3.2 compatibility results, but identify maintained versions for new installations. [Official maintenance status, checked 2026-09-25](https://www.ruby-lang.org/en/downloads/branches/).

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

Current first action: Correct the 13 effects that diverge from the pinned JavaScript oracle at nondefault settings (classicNoisedeck/noise3d, filter/craquelure, filter/median, filter/spookyTicker, mixer/shapeMask, points/dla, render/pointsBillboardRender, render/render3d, render/renderCubemap3d, synth/gradient, synth/mandelbrot, synth/testPattern, synth3d/flythrough3d), then re-run the extended sweep and the required checks. Continue GAP-002's isolated-installation workflow evidence in parallel.
Subsequent historical actions remain dependent on that evidence. No implementation is authorized by this audit.

1. Authority identities for GAP-001 are resolved and recorded (current lock pins CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c29045c1b91af94887a8ff20106e980ef`; historical pins, goldens, tolerances, and exclusions preserved). The locked comparator and extended sweep ran; evidence is committed under [evidence/gap-001](evidence/gap-001/parity-evidence-summary.json).
2. Execute the installed workflow for GAP-002. Record meaningful output, failure recovery, versions, and cleanup.
3. Correct the 13 diverging effects and re-run compiler and rendered parity for GAP-001. Keep structural, numerical, and platform evidence separate.
4. Qualify distribution contents and lifecycle for GAP-003 after the installed workflow passes.
5. Record measured results. Close entries only when their acceptance criteria pass.

Implementation belongs to the separate job. Do not port additional effects or advance the current parity checkpoint through this register.

## 6. Pass history

2026-09-25 daily review at `d7942883e2e56486dd6c186486cd794cc3a512a4`: source freshness and bounded evidence reviewed. Open qualification limits retained. Retained review evidence: Actions run 36076250675 (retained by the operator review; exact-source Actions are linked above). No new closure claimed.

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-26 | this commit | Extended GAP-001 qualification: comparator run at the pinned authority, extended sweep evidence committed, authority repin documented, operator-local evidence links removed. GAP-001 remains open (13 diverging effects). | Default gate 205/205 byte-exact (Ruby 3.2.8 and 3.4.5); extended sweep 1607/1625 cases exact with every case, exclusion, error, and tolerance recorded. | 13 effects differ at nondefault settings; installed workflow, platforms, and releases remain unqualified. |
| 2026-09-24 | `379aa03df26df8b17f6916535c83328bb0e8eaa3` | Created six-section register and README link. No closures. | Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `20260924-remaining-gap-documents`.
Operational evidence (operator-retained; not committed to this repository). Creating this register does not advance successful-audit timestamps or the rotation.
