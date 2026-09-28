# noisemaker-for-ruby: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Scheduled audit: 2026-09-28. Current inspected source: [`b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8). Local `main` matched remote before checks. Checkout clean.
Full rendered parity remains **unverified**. GAP-001 stays open. GAP-002 closed for a measured matrix. No release approval follows from this audit.
Pinned authority: CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1`, upstream `2f47612c29045c1b91af94887a8ff20106e980ef` (lock unchanged). All executed checks bound this pin.
Current CPU authority head: `21d211e0f3dcdf409b197fb5d212aac706fc75e0`. It is newer than the pin and unqualified for this port. Pin updates belong to the sync job.
Upstream discovery: `73c15be00d6888f4b5d2835d8e242ee9e840df45`. CDN `/1.0/` manifest SHA-256 `05c4d7b7744837ae90a3bb4c89e5403ff09448a74d9d7e824abb3d719ad3314e` is unchanged. It still holds 210 effect IDs.
Current served kit: `0.1.9`, source `91ae3f6008001678d311dbc06f1f485c577d71ce`. All 329 served files match the kit inventory hashes. 327 files are byte-identical to that source. `LICENSES/noisemaker-MIT.txt` is byte-identical to the upstream `2f47612c` license. `compat.json` lists exactly the 205 bundled IDs.
`rubygems.org` returns 404 for this package. Distribution is build-from-checkout plus the export kit.

Daily review: 2026-09-25. Previously inspected source: [`d7942883e2e56486dd6c186486cd794cc3a512a4`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/d7942883e2e56486dd6c186486cd794cc3a512a4).

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
| CLAIM-001 | [Historical source](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | 205 exact RGBA8 comparisons at 8 by 8, seed 1, time 0.25, with bounded volumes and explicit particle scenes. | supported | Audit 2026-09-28 re-executed `ruby scripts/parity.rb` at `b02f816` with the pinned oracle. Result: 205 of 205 byte-exact, exit 0. Default gate only. GAP-001 covers broader coverage. |
| CLAIM-002 | [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | Human usability: installation, output, errors, and recovery | supported | Audit 2026-09-28 installed the built gem on Ruby 3.4.5 Linux. Discovery, first render, filter, DSL, library API, diagnostics, recovery, cancellation, file preservation, and removal pass. See section 3. Windows stays unmeasured. |
| CLAIM-003 | [Ecosystem reference](https://guides.rubygems.org/make-your-own-gem/) | Ecosystem fit and version support | partial | Gemspec metadata is correct: MIT license, `required_ruby_version >= 3.2`, homepage, MFA metadata. No runtime gem dependencies. The 3.2 floor is end of life since 2026-04-01. CI covers 3.2, 3.3, 3.4, and 4.0. |
| CLAIM-004 | [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | Release readiness | unverified | GAP-001 keeps full parity open. `rubygems.org` holds no published version. GAP-003 tracks the remaining distribution checks. |
| CLAIM-005 | [Exact-source Actions](https://github.com/noisefactorllc/noisemaker-for-ruby/actions?query=head_sha%3A379aa03df26df8b17f6916535c83328bb0e8eaa3) | Workflow status only | supported | [Ruby CI and export kit](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/35820283884): `success`. |
| CLAIM-006 | [Runtime-source Actions](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/36256396160) | CI covers the shipped runtime | supported | Run 36256396160 at `91ae3f6` passed all six jobs. Ruby 3.2, 3.3, 3.4, 4.0 on Linux and 4.0 on macOS are green. Pinned parity: 205/205 byte-exact. Integration: 229 runs, 1,426 assertions, six skips. `lib`, `exe`, and tests are identical at `91ae3f6` and `b02f816`, so the run binds the current runtime. |
| CLAIM-007 | [Sweep inventory in this file's 2026-09-26 update](docs/evidence/gap-001/parity-sweep-report.json) | Inventory table asserted executed parity for all 210 listed IDs | contradicted | Five manifest IDs (`render/meshLoader`, `render/meshRender`, `synth/roll`, `synth/scope`, `synth/spectrum`) sit outside the bundle and the sweep. Their table rows claimed execution falsely. This audit corrected the rows in [COMPATIBILITY.md](COMPATIBILITY.md#3-parity-coverage). |

## 3. Methods and evidence

### Scheduled audit, 2026-09-28

Environment: Linux 6.8.0-134-generic x86_64 container. Portable Ruby 3.4.5, Node 26.5.1. Oracle: clean clone of `noisemaker-for-cpu` at pinned `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1`. No GPU, macOS, Windows, or ffmpeg in this container.

Executed commands and results:

```sh
ruby scripts/parity.rb            # NOISEMAKER_CPU_DIR=pinned oracle clone
# exit 0. PARITY: 205/205 pass (byte-exact), 0 diff, 0 runtime-error, 0 oracle-error.

ruby scripts/parity-sweep.rb --only <13 diverging effects> --report sweep-13.json
# exit 1 by design: 107 cases, 89 exact, 17 diff, 1 ruby-error, 0 oracle-error.
# The non-exact cases match the committed 2026-09-26 report case for case.

rake test                          # clean source archive of b02f816, no oracle
# exit 0. 229 runs, 1336 assertions, 0 failures, 0 errors, 24 skips.
# Skips are oracle-dependent, video, and opt-in live-CDN checks.

gem build noisemaker-for-ruby.gemspec   # in isolated copy; sha256 5eb3bed694f9e4ae714498bdcc2e7bc79a70e8997a5a562195500667ce2887d7
GEM_HOME=<isolated> gem install --no-document ./noisemaker-for-ruby-0.0.0.gem
# exit 0, 326 installed files.
```

Installed-gem probes, all through the public entry points:

```sh
noisemaker-rb effects | wc -l              # 205
noisemaker-rb describe synth/curl          # parameters and ranges print
noisemaker-rb generate synth/solid --width 64 --height 64 --param 'color=#4080c0' --filename solid.png
# exit 0. PNG magic 89504e470d0a1a0a, 158 bytes.
noisemaker-rb generate synth/curl --width 32 --height 32 --seed 1 --param scale=16 --filename curl.png
noisemaker-rb apply filter/lighting curl.png --filename lit.png   # exit 0
printf 'search synth, filter\nnoise(seed: 3, ridges: true).vignette().write(o0)\nrender(o0)\n' |
  noisemaker-rb run --width 32 --height 32 --filename noise.png    # exit 0
noisemaker-rb generate synth/nope ...      # "Unknown effect: synth/nope" exit 2
noisemaker-rb generate synth/solid --param 'color=zzz' ...
# names effect and parameter, exit 2. Corrected input then renders, exit 0.
ruby -e 'require "noisemaker-for-ruby"; ...'   # library render and filter pass
ruby -e 'require "noisemaker_cpu"; ...'        # alternate require name loads
noisemaker-rb animate synth/solid --width 32 --height 32 --frame-count 3 --save-frames frames --filename solid.mp4
# no ffmpeg: exit 0, "ffmpeg not found; wrote 3 frames to frames (no video).", frames retained
# Cancellation (subprocess with default signal dispositions, SIGINT at 2 s):
noisemaker-rb generate synth/mandelbrot --width 256 --height 256 --param iterations=2000 --filename out.png &
# SIGINT: exits immediately (signal status -2), pre-existing out.png stays byte-identical
noisemaker-rb animate synth/curl --width 16 --height 16 --frame-count 12 --save-frames aframes --filename anim.mp4 &
# SIGINT at 2 s: exits immediately, frame_0000.png retained, no partial video file
noisemaker-rb generate synth/solid --width 16 --height 16 --filename after.png
# post-interrupt recovery: exit 0, valid PNG. Cancelled runs print a raw Ruby Interrupt trace
gem uninstall noisemaker-for-ruby -a -x    # exit 0, executable removed
```

Served-kit byte checks, executed against `https://kits.noisedeck.app/ruby/0/`:

- All 329 files match the `kit.json` SHA-256 and byte counts.
- 327 files are byte-identical to `git show 91ae3f6:<mapped path>` under the `kit.config.json` mappings.
- `LICENSES/noisemaker-MIT.txt` is byte-identical to `noisemaker@2f47612c` `LICENSE`.
- `compat.json` effect IDs equal the 205 bundled IDs.

Carried-evidence check: the committed sweep report records 353 candidate source hashes. 352 match `git show b02f816:<path>`. The one mismatch is `Gemfile.lock`, which is not tracked in Git. The runtime, harness scripts, and lock are unchanged since the 2026-09-26 runs.

Fleet observation pass: all 15 eligible ports reconciled through the GitHub API. Newly observed heads recorded in the shared rotation state as awaiting classification and parity. C++ excluded by name and ID.

### Daily review, 2026-09-25

Exact-source CI reports 205 of 205 default CPU cases byte-exact. Its integration test log reports 229 runs, 1,426 assertions, and six skips. Standalone variants retain 24 skips. Five current effect IDs and broader parameters, state, platforms, and installed workflows remain unqualified. This is bounded evidence, not full parity. Raw CI log for Actions run 36076250675 (retained by the operator review — exact-source Actions are linked above).
The review checked source changes, worker evidence, source-bound CI where present, and current served inventories. Full installed-host and platform qualification remains incomplete.

Environment: macOS 26.5, Darwin arm64.
SHA-256 source-hash records for the 2026-09-26 qualification runs are committed at [parity-evidence-summary.json](evidence/gap-001/parity-evidence-summary.json).
Raw command and remote evidence for the 2026-09-24 register (operator-retained, not committed to this repository).

Executed command:

```sh
ruby -Ilib:test test/test_public_api.rb
```

Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. Final exit code: 0.
No image denominator or tolerance follows from a unit-test or generated-file result.
Official reference: [Current RubyGems guide, accessed 2026-09-24](https://guides.rubygems.org/make-your-own-gem/).

| Outcome | Observed scope | Remaining work |
|---|---|---|
| Installation | Verified 2026-09-28: built gem installed in an isolated `GEM_HOME` on Ruby 3.4.5 Linux. | Test the EOL 3.2 floor outside CI and Windows when hosts exist. |
| First useful output | Verified 2026-09-28: `generate` and `apply` rendered valid PNGs. DSL and library renders pass. | None for the measured scope. |
| Host integration | Verified in measured scope: parameters, external image inputs, DSL chains, both require names. | Stateful iteration and broader chains stay inside GAP-001 coverage. |
| Errors and recovery | Verified 2026-09-28: invalid effect and invalid parameter print clear diagnostics, exit 2, and recovery follows. | None for the measured scope. |
| Cancellation and file preservation | Verified 2026-09-28: SIGINT exits at once, preserves an existing output file, and retains frames written before the interrupt. | Cancelled runs print a raw Ruby Interrupt trace. |
| Distribution | Verified 2026-09-28: served kit 0.1.9 byte-checked in full. Gem metadata checked. Removal passes. | `rubygems.org` publication, upgrade behavior, and Windows remain open (GAP-003). |
| Accessibility | CLI diagnostics checked. No graphical interface ships, so keyboard and focus checks do not apply. | Keep CLI diagnostics readable. |

Headless libraries do not require an editor accessibility test. Their CLI diagnostics and failure handling still require checks.
Host presence does not prove host qualification. This pass made no global installation or user-project changes.

## 4. Known gaps

P1 means false completion or major correctness failure. P2 means coverage or integration uncertainty. P3 means documentation inconsistency.
These entries record missing qualification. They do not infer implementation defects from absent tests.

### GAP-001: current authority and parity qualification

- Status: open. Priority: P2. Category: verification.
- Affected scope: noisemaker-for-ruby.gemspec, scripts/oracle-lock.json, scripts/parity.rb, scripts/parity-sweep.rb, test/, README.md
- Expected behavior: Reproducible evidence binds each supported claim to the port and authority revisions.
- Observed behavior: Default gate is 205 of 205 effects byte-exact at the pinned authority on Ruby 3.2.8 and 3.4.5. The extended sweep covered 1625 cases: nondefault parameters, animation, iterated state, seed 7, 16x16, and volumeSize 8, at byte-exact tolerance. It found 17 differing cases across 13 effects and one Ruby runtime error (synth/testPattern pattern=colorBars). See "GAP-001 qualification runs, 2026-09-26" below and section 3. Audit 2026-09-28 re-ran the default gate fresh at `b02f816`: 205/205 byte-exact, exit 0. The same audit re-ran the sweep for the 13 diverging effects. Result: 107 cases, 89 exact, 17 differing cases with the same maxdiff values, and the same Ruby runtime error. The committed divergence evidence is re-verified by fresh execution.
- Evidence: [Raw sweep report](evidence/gap-001/parity-sweep-report.json), [evidence summary with source hashes](evidence/gap-001/parity-evidence-summary.json), [raw Ruby 3.2.8 default-gate log](evidence/gap-001/parity-default-ruby-3.2.8.log), [compatibility matrix](COMPATIBILITY.md#3-parity-coverage), and section 3.
- Next action: Correct the 13 diverging effects (classicNoisedeck/noise3d, filter/craquelure, filter/median, filter/spookyTicker, mixer/shapeMask, points/dla, render/pointsBillboardRender, render/render3d, render/renderCubemap3d, synth/gradient, synth/mandelbrot, synth/testPattern, synth3d/flythrough3d), then re-run the extended sweep and the required checks.
- Dependencies: Immutable authority inputs are resolved and recorded (current lock pins CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c29045c1b91af94887a8ff20106e980ef` via sync commits `47a863d`, `0261bcf`, `0984199`; historical pins, goldens, and tolerances preserved). Release claims additionally need GAP-003.
- Acceptance criteria: Report every applicable case, parameter choice, exclusion, error, and tolerance. Do not reduce the denominator to report success.
- Required checks: Existing compiler and rendered parity gates, with raw output and exact source hashes.
- Last verification: 2026-09-28. Full behavior qualification remains unverified: 13 effects differ from the pinned JavaScript oracle at nondefault settings, re-verified by fresh execution.

### GAP-001 qualification runs, 2026-09-26

The locked 205-effect comparator ran at the pinned authority `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` (upstream `2f47612c29045c1b91af94887a8ff20106e980ef`, verified clean checkout) against Ruby 3.2.8 and Ruby 3.4.5. All runs were executed on a clean tree at pre-publication HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc` (each run's header records that HEAD with `git_dirty: false`); the published candidate adds only the committed evidence files, which sit outside the harness source-hash globs, so `candidate.source_hashes` in the committed report are identical at that HEAD and at this commit (verified after the final amend). The default gate (size 8, seed 1, time 0.25, one scene per effect) is 205 of 205 effects byte-exact on Ruby 3.2.8 (gate transcript: [parity-default-ruby-3.2.8.log](evidence/gap-001/parity-default-ruby-3.2.8.log) — annotated provenance header lines 1-5 added by the invocation wrapper, followed by parity.rb's raw output and exit status). The extended sweep ([raw report](evidence/gap-001/parity-sweep-report.json), [summary with source hashes](evidence/gap-001/parity-evidence-summary.json)) executed 1625 RGBA8 cases across all 205 effects — default scene, up to 3 nondefault-parameter cases per effect (560 executed, 922 parameters excluded with reasons in the report: 826 capped, 41 without a derivable nondefault value, 55 bound via inputs), animation times 0.0 and 1.0, iterated state at iterationCount 3, seed 7, 16x16 scenes, and volumeSize 8 for volume effects — with byte-exact RGBA8 tolerance and no skipped or tolerated differences. 1607 cases are byte-exact; 17 cases across 13 effects differ (maxdiff 1-255) and one Ruby runtime error was observed (synth/testPattern with pattern=colorBars: "can't convert Array into Float"). These are port defects at nondefault settings, listed per effect in the [compatibility matrix](COMPATIBILITY.md#3-parity-coverage) and the evidence summary. The extended sweep ran on Ruby 3.4.5; the committed report is the output of the committed `scripts/parity-sweep.rb` in `--merge` mode (its header records the full merge invocation; the per-run `command` fields in the shard reports record the bare invocation because an option-parsing bug dropped arguments before the field was written, fixed in the committed harness; each run records its ruby version, HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc`, and `git_dirty: false`; the committed harness hash is in the summary). Exact-source CI for these documents is the publication gate; run ids are cited in the evidence summary and section 2. Full behavior qualification remains open until the 13 diverging effects are corrected and re-swept.

### GAP-002: installed developer workflow qualification

- Status: closed for the qualified matrix (2026-09-28 audit). Priority: P2. Category: usability.
- Affected scope: Public API, examples, supported hosts, errors, recovery, and lifecycle.
- Expected behavior: Developers can install, produce useful output, integrate it, recover from errors, and remove the package.
- Observed behavior: Audit 2026-09-28 installed the built gem from a `b02f816` source archive into an isolated `GEM_HOME`. Discovery, first render, filter application, DSL run, library API, invalid-input diagnostics, and removal all pass. Cancellation and file preservation pass: SIGINT mid-render exits immediately, keeps an existing output file byte-identical, and retains frames already written by `animate`. Exact-source CI at the identical runtime `91ae3f6` covers Ruby 3.2, 3.3, 3.4, and 4.0 on Linux and 4.0 on macOS.
- Evidence: Command transcripts and results in section 3, [Actions run 36256396160](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/36256396160), and [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md).
- Next action: Keep this gap closed while entry points stay unchanged. Windows and any GUI accessibility checks need a Windows host; record them as unqualified until one exists.
- Dependencies: None open for the qualified matrix. A Windows host is unavailable in this harness.
- Acceptance criteria: Artifact hashes, steps, meaningful output, error diagnostics, recovery results, cancellation and file-preservation results, and cleanup results are recorded in section 3. Minimum and current versions are covered by CI at the identical runtime.
- Required checks: Installed workflow probes above and the CI version matrix at `91ae3f6`. Cancellation and file preservation are measured in section 3. Unavailable platforms stay explicit.
- Last verification: 2026-09-28. Closed for the qualified matrix; Windows remains unqualified.

### GAP-003: distribution and release qualification

Ruby 3.2 reached end of life on 2026-04-01. Ruby lists 3.4 and 4.0 under normal maintenance. Preserve 3.2 compatibility results, but identify maintained versions for new installations. [Official maintenance status, checked 2026-09-25](https://www.ruby-lang.org/en/downloads/branches/).

- Status: open. Priority: P2. Category: release.
- Affected scope: Actual artifact, dependencies, notices, version promises, and release evidence.
- Expected behavior: The delivered artifact supports its documented installation and first useful result.
- Observed behavior: Audit 2026-09-28 byte-verified the served kit `0.1.9` in full. All 329 inventory hashes match. 327 files are byte-identical to source `91ae3f6`. The upstream notice matches `noisemaker@2f47612c`. Gem build, isolated install, metadata, and removal pass (section 3). Upgrade behavior is untested: only one kit version and one gem version exist. `rubygems.org` holds no published version.
- Evidence: Section 3, [kit metadata](https://kits.noisedeck.app/ruby/0/deployment-meta.json), and exact-source CI in section 2.
- Next action: The owner decides the `rubygems.org` publication path. After a published version exists, test an upgrade in an isolated consumer. Close this gap after GAP-001 passes and the upgrade check runs.
- Dependencies: GAP-001 full parity. A published artifact or an explicit build-from-checkout release decision.
- Acceptance criteria: Match artifact bytes to their inventory (done 2026-09-28). Check notices and dependencies (done 2026-09-28). Pass installation, examples, upgrade, and removal. Upgrade remains untested.
- Required checks: Inspect exact-source CI jobs and render legs (done at `91ae3f6`). Count skips and errors rather than trusting green summaries.
- Last verification: 2026-09-28. This register does not approve a release.

## 5. Ordered next actions

Current first action: the implementation job corrects the 13 effects that diverge from the pinned JavaScript oracle at nondefault settings. They are classicNoisedeck/noise3d, filter/craquelure, filter/median, filter/spookyTicker, mixer/shapeMask, points/dla, render/pointsBillboardRender, render/render3d, render/renderCubemap3d, synth/gradient, synth/mandelbrot, synth/testPattern, synth3d/flythrough3d. It then re-runs the extended sweep and the required checks.
Subsequent actions depend on that evidence. No implementation is authorized by this audit.

1. GAP-001: correct the 13 diverging effects, then re-run the extended sweep with unchanged denominators and tolerances.
2. GAP-003: decide the `rubygems.org` publication path. After a published version exists, run an isolated upgrade test.
3. GAP-003: run the Windows platform checks when a Windows host is available.
4. Keep GAP-002 evidence current whenever entry points change. Re-run the installed workflow probes after any CLI or library change.
5. Keep GAP-001 evidence current at each authority or source change. Pin updates belong to the sync job.

Implementation belongs to the separate job. Do not port additional effects or advance the current parity checkpoint through this register.

## 6. Pass history

2026-09-25 daily review at `d7942883e2e56486dd6c186486cd794cc3a512a4`: source freshness and bounded evidence reviewed. Open qualification limits retained. Retained review evidence: Actions run 36076250675 (retained by the operator review — exact-source Actions are linked above). No new closure claimed.

2026-09-28 scheduled audit at `b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`: default parity gate re-executed 205/205 byte-exact at the pinned oracle. The focused sweep re-ran the 13 diverging effects and reproduced the committed non-exact cases. GAP-002 closed for the qualified matrix. Served kit `0.1.9` byte-verified in full. Five false inventory rows corrected in COMPATIBILITY.md. No release approval.

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-28 | `b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8` | This audit: fresh default-gate execution, focused divergent sweep, installed-workflow probes, served-kit byte verification, carried-evidence hash check, five false inventory rows corrected. GAP-002 closed for the qualified matrix. | Default gate 205/205 byte-exact (Ruby 3.4.5, pinned oracle). Focused sweep 107 cases: 89 exact, 17 diff, 1 error, matching the committed report. Standalone suite 229 runs, 24 skips. Kit 329/329 hashes. Gem install, probes, and removal pass. Cancellation and file preservation pass. | 13 effects diverge off-default. Full parity, upgrade, rubygems publication, and Windows remain open. |
| 2026-09-26 | this commit | Extended GAP-001 qualification: comparator run at the pinned authority, extended sweep evidence committed, authority repin documented, operator-local evidence links removed. GAP-001 remains open (13 diverging effects). | Default gate 205/205 byte-exact (Ruby 3.2.8 and 3.4.5); extended sweep 1607/1625 cases exact with every case, exclusion, error, and tolerance recorded. | 13 effects differ at nondefault settings; installed workflow, platforms, and releases remain unqualified. |
| 2026-09-24 | `379aa03df26df8b17f6916535c83328bb0e8eaa3` | Created six-section register and README link. No closures. | Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `audit-20260928-035500`. This run's raw evidence: shared series store at `/series/evidence-audit-20260928-035500/`.
Earlier runs: `20260924-remaining-gap-documents`, the 2026-09-25 daily review, and the 2026-09-26 extended qualification.
Operational evidence (operator-retained, not committed to this repository). Creating this register does not advance successful-audit timestamps or the rotation.
