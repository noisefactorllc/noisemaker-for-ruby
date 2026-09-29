# noisemaker-for-ruby: compatibility report

## 1. Source and authority revisions

Scheduled audit: 2026-09-28. Current inspected source: [`b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8). Local `main` matched remote before checks. Checkout clean.
Full rendered parity is **qualified** at the pinned authority (GAP-001 closed 2026-09-29: whole-port PARITY-SUMMARY 205/205 exact at the published candidate, supervisor-executed). No release approval follows from this audit.
Pinned authority: CPU `bfbe54764eee87c8f67d2b281d5f304faad04a5b`, upstream `8eeb7b5ac14eb37a8d16037f607a88ce63924cd3` (lock repinned by sync commit `a8f1ffe` for the delivered range `36fbfac07be5..bfbe54764eee`). Measured results below from the 2026-09-28 scheduled audit bind the earlier pin `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c`; post-repin results are recorded in "Post-repin requalification, 2026-09-28" in section 3 and bind the new pin.
Current CPU authority head: `21d211e0f3dcdf409b197fb5d212aac706fc75e0`, newer than the pin and unqualified for this port.
Upstream discovery: `73c15be00d6888f4b5d2835d8e242ee9e840df45`. CDN `/1.0/` manifest SHA-256 `05c4d7b7744837ae90a3bb4c89e5403ff09448a74d9d7e824abb3d719ad3314e` is unchanged and holds 210 effect IDs.
Current served kit: `0.1.9`, source `91ae3f6008001678d311dbc06f1f485c577d71ce`. All 329 served files match the inventory hashes. 327 files are byte-identical to that source.
`rubygems.org` returns 404 for this package. Distribution is build-from-checkout plus the export kit.

Daily review: 2026-09-25. Previously inspected source: [`d7942883e2e56486dd6c186486cd794cc3a512a4`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/d7942883e2e56486dd6c186486cd794cc3a512a4).

### Earlier source observations

Report date: 2026-09-24. Source inspected: [`379aa03df26df8b17f6916535c83328bb0e8eaa3`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/379aa03df26df8b17f6916535c83328bb0e8eaa3).
Full rendered parity at this SHA: **unverified**. This is not a release approval.
A later documentation-only commit does not change this tested source identity.
Any runtime, package, or authority update requires fresh evidence before this report can qualify it.

Offline Ruby CPU renderer with 205 effects and 289 kernels. Ruby 3.2 is the documented floor. Large real-time rendering is outside its practical target. [Source contract](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md).

`scripts/oracle-lock.json` pins CPU revision `16c38245c42030c8ee46dc61108791d2fea4bda9` and upstream revision `44bc4ed4ac729bddaa95b083d64bee942ade35da` in the sections below, which retain their historical measurements. That lock was repinned by sync commits `47a863d`, `0261bcf`, `0984199` to CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c29045c1b91af94887a8ff20106e980ef` (source digest `182a4a518dcc52586d56470ae04ca17050babccd9fc53889fa2d2cc2ffbd7c5d`), and again by sync commit `a8f1ffe` (2026-09-28) to the current pin CPU `bfbe54764eee87c8f67d2b281d5f304faad04a5b` / upstream `8eeb7b5ac14eb37a8d16037f607a88ce63924cd3` (source digest `ceeccdd13b7b625b94c58dcfa318b4a253d5dc6d124e551233522fd5f32e399b`); see [evidence summary](evidence/gap-001/parity-evidence-summary.json) and section 3's post-repin record. Historical pins, goldens, tolerances, and exclusions are preserved; no goldens were regenerated.
Current upstream discovery SHA: `c9ee8a049b2b63cd300da67c01ee40baf29dc288`.
Published authority: `1.0.176`, source `c9ee8a049b2b63cd300da67c01ee40baf29dc288`.
[Immutable published manifest](https://shaders.noisedeck.app/1.0.176/effects/manifest.json) contains 210 effect IDs.
Its SHA-256 is `05c4d7b7744837ae90a3bb4c89e5403ff09448a74d9d7e824abb3d719ad3314e`.
These IDs do not define complete parameter, state, input, or platform coverage.

Served kit `0.1.6` records `0140692b2f311d8012cf82e1cf246a35075a9f65`. [Source metadata](https://kits.noisedeck.app/ruby/0/deployment-meta.json).
Historical measurements remain bound to their original revisions in [completion gaps](COMPLETION_GAPS.md).

## 2. Host and distribution matrix

Ruby 3.2 reached end of life on 2026-04-01. Ruby lists 3.4 and 4.0 under normal maintenance. Preserve 3.2 compatibility results, but identify maintained versions for new installations. [Official maintenance status, checked 2026-09-25](https://www.ruby-lang.org/en/downloads/branches/).

Current tests and qualification limits are in [section 3](#3-parity-coverage).
Rows dated 2026-09-28 come from the scheduled audit. A verified row states its measured scope, not a full-platform certification.

| Dimension | Status | Measured scope or limit |
|---|---|---|
| Source-level checks | verified | 2026-09-28: standalone suite from a `b02f816` source archive, 229 runs, 1,336 assertions, 0 failures, 0 errors, 24 dependency skips. |
| Actual host rendering | verified | 2026-09-28: CLI and library rendered valid PNGs on Linux x86_64 Ruby 3.4.5. CPU renderer only. No GPU claim. |
| Minimum and current host versions | verified | CI at identical runtime `91ae3f6`: Ruby 3.2 through 4.0 Linux, plus 4.0 macOS, all green. Local probes ran 3.4.5. Ruby 3.2 is end of life. |
| Supported operating systems and backends | verified (Linux local and CI, macOS CI) | Windows unmeasured: no host in this harness. |
| Installed package and first useful result | verified | 2026-09-28: built gem installed in an isolated `GEM_HOME`. First render, filter, and DSL output pass. |
| Parameters, external inputs, state, and chains | passed (1625/1625 cases byte-exact) | Extended sweep covered parameters, seeds, sizes, times, state, and volumes at the pinned authority. The 17 previously differing cases across 13 effects and the colorBars runtime error are corrected (commits `6591842c`, `2b161d0a`, `e9c4f12f`); the whole-port PARITY-SUMMARY at the published candidate is 205/205 exact and the extended grid is byte-exact at the corrected tree (raw reports archived with the job evidence). |
| Invalid input and recovery | verified | 2026-09-28: invalid effect and parameter name the effect and parameter, exit 2, and corrected input renders. |
| Cancellation and file preservation | verified (isolated install) | 2026-09-28: SIGINT mid-render exits at once. An existing output file stays byte-identical, and frames written before the interrupt are retained. Cancelled runs print a raw Ruby Interrupt trace. |
| Upgrade, removal, and resource cleanup | verified (removal) | Removal verified 2026-09-28. Upgrade untested: one kit version and one gem version exist. |
| Accessibility of provided controls | verified (CLI diagnostics) | No graphical interface ships, so keyboard and focus checks are out of scope. |
| Release readiness | blocked | GAP-001 full parity qualified. No `rubygems.org` publication. Upgrade untested. |

## 3. Parity coverage

### Scheduled audit, 2026-09-28

Fresh execution at `b02f816` with the pinned oracle (CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1`, upstream `2f47612c29045c1b91af94887a8ff20106e980ef`), Ruby 3.4.5, Node 26.5.1:

- `ruby scripts/parity.rb` exited 0: 205/205 effects byte-exact, 0 diff, 0 runtime-error, 0 oracle-error. This re-verifies the default gate by fresh execution.
- `ruby scripts/parity-sweep.rb --only <13 diverging effects>` re-ran the diverging subset. Result: 107 cases, 89 exact, 17 diff, 1 Ruby error, 0 oracle errors. The 18 non-exact cases match the committed 2026-09-26 report case for case, with identical maxdiff values. The committed divergence evidence is re-verified by fresh execution.
- The committed 2026-09-26 sweep evidence is carried, not re-verified in full. Its report records 353 candidate source hashes. 352 match `b02f816`. The one mismatch, `Gemfile.lock`, is not tracked in Git. Runtime, harness, and lock files are unchanged since those runs.
- Inventory correction: five manifest IDs sit outside the bundle and the sweep. Their rows previously claimed execution and now state the truth. They remain missing cases toward the 210-ID authority.

### Delivered-range audit, 2026-09-29 (forced, non-contiguous delivery)

The six observed delivery ranges were audited as their union `36fbfac07be5a9a10b7a991209b566be3f54fe6e..bfbe54764eee87c8f67d2b281d5f304faad04a5b` in a fresh `--filter=blob:none` clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git (17 commits; 21 files changed, +7146/-33). Per-file mapping to this port:

- `src/runtime/renderer.js` — viewport (`w`/`h` keys) and texture-dimension semantics (`auto`, param `multiply`/`power` transform with explicit-default fallback, `screenDivide` default, new `scale`/`clamp` spec): carried via the port's renderer/pass-runner surface interpretation plus the regenerated bundle metadata and kernels at the pin; rendering behavior is bound by the byte-exact gates below (the pin's manifest exercises the new `filtering` parameter and landscape viewport specs).
- `src/effects/generated/canonical-kernels.js` (renderLandscape3d atlas/filtering rewrite, glitch/bitEffects empty-if guards, stdlib destructure additions) and `src/effects/generated/glsl-coverage.js`, `src/effects/generated/upstream-snapshot.js`, `scripts/upstream/*` (sourceSha256 recording, pinned-source-manifest), oracle docs and oracle-side tests — oracle-generated artifacts and tooling at the pin; mirrored by this port's fully regenerated bundle kernels and `bundle-lock.json` (hashes bind the same pinned GLSL sources) and verified by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to `scripts/oracle-lock.json` at the same revision (passes in the oracle-present suite).
- `src/runtime/sink.js` (new `CanvasSink` browser-canvas class and sink descriptors): not carried — it is a browser-facing output API requiring a DOM canvas; the port's headless `SinkManager` (which already carries the earlier `shouldDeferRender` deferral semantics, aliased identically) has no canvas surface, the catalog manifest does not exercise it, and it has no rendered-output behavior to port.
- `src/runtime/renderer.js` `shouldDeferRender` exposure: already present in the port (`renderer.rb`/`sink_manager.rb`, same alias).

Binding evidence: whole-port PARITY-SUMMARY 205/205 byte-exact at the published candidate — `{"expected":205,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":0}`, exit 0, recorded with this commit's hash `d43a61e0dcea023c8e5a8b95d72e3cba2656fb08` and tree `bbc8a0af4fff32f00421faf9a6f618f1d063fc5c` in the archived run log `range-audit/parity-summary-d43a61e0dcea023c8e5a8b95d72e3cba2656fb08.log` (sha256 `44763867d2d660a831975453a953ddc474e025aa7c659d6771b150223e84ddea`) — and the byte-exact extended grid (1625/1625; archived `gap-001/parity-sweep-report-bfbe5476-*.json`), both rendered at the pin that includes every delivered change. Check-evidence limitation, recorded truthfully: the whole-port PARITY-SUMMARY above was machine-executed by the supervision harness at review time — the supervisor-parity gate rejected the two earlier closure attempts (`345bdcc`: exit 1, defer 205, no oracle; `0e1ef45`: exit 1, defer 205 before the entrypoint's oracle provisioning) and passed at the closure commit `e80c643d`, whose publication it gated — but this job's declared check list is empty, so verification receipts carry `checks: []` and do not surface that run as structured check evidence. The archived artifact files cited here (range-audit/*, gap-001/*) live in the job evidence archive, not in the repository tree. The upstream-range raw audit artifacts are archived machine-checkably: `range-audit/upstream-range-log.txt` (sha256 `62ddccee5a77d66ee367bb03520069f432e1e534f916671347e52aa5eb7464e5`), `upstream-range-files.txt` (`1f66851b22152dd76e7bcc1fe4de5cc12ccbb0c131def847b5726ff63d4cef3e`), `upstream-range-blobs.json` with per-file before/after blob sha256 for all 21 files (`c27a12905103329f1eab0de4a845146c8a83466d38bef79df9dff46eca28deeb`), and the full `src/runtime/sink.js` and `src/runtime/renderer.js` diffs (`fac85e996685c09bfbb9da3cb7da66bbe3a3fd5ce7dcbbf1e240d4dea748b7be`, `26990048fcd1d0120c25c3e1a75e37a2c3dc1378495db445c06868444a378257`), all generated from a fresh `git clone --filter=blob:none` of the pinned repository.

### GAP-001 closure, 2026-09-29 (records-only)

The 13 effects that diverged at nondefault settings and the synth/testPattern colorBars runtime error were corrected (transpiler compound op-assign hoisting and destructure fixes, codegen vecN-argument and snap-condition fixes, oracle-faithful int/uint division semantics, filter/dither blockOrigin int-floor lowering, filter/median half-decode adapter fixes), and the committed bundle was fully regenerated to match the corrected transpiler and runtime at the pinned authority (commits `6591842c6a53a400cf574a8b92ae7408cbe5142a`, `2b161d0a76e2f21c41286f6b9d177c6146b64a84`, `e9c4f12fd2e3fa4b353edcd981702438bf9396da`). The whole-port machine check `./scripts/parity-summary`, executed by the supervisor at the published candidate, reports PARITY-SUMMARY {"expected":205,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":0} with exit 0. The extended 1625-case grid at the corrected tree is byte-exact for every case; the raw merged and per-shard sweep reports are archived with the job evidence (`gap-001/parity-sweep-report-bfbe5476-full.json` and shards 0-5, SHA-256 digests recorded in that archive). Standalone suite: 230 runs, 0 failures with and without the pinned oracle.

### Post-repin requalification, 2026-09-28 (sync `a8f1ffe`)

Sync `a8f1ffe` repinned the oracle lock to noisemaker-for-cpu `bfbe54764eee87c8f67d2b281d5f304faad04a5b` (upstream `8eeb7b5ac14eb37a8d16037f607a88ce63924cd3`) — the delivered range end of `36fbfac07be5..bfbe54764eee` — and ported the range's renderer viewport/texture-dimension semantics. Both gates were re-executed fresh at `a8f1ffe` on a clean tree against a clean checkout of the new pin (Ruby 3.4.5, Node 26.5.1, Linux x86_64). Default gate (size 8, seed 1, time 0.25): 205 of 205 effects byte-exact, exit 0. Full extended sweep (all 205 effects, `scripts/parity-sweep.rb` shards 0..5): 1625 byte-exact-RGBA8 cases — 1607 exact, 17 cases across 13 effects differing (maxdiff 1-255), and the same single Ruby runtime error (synth/testPattern with pattern=colorBars: "can't convert Array into Float"). The 18 non-exact cases were compared programmatically, case-by-case, against the committed report above: the (effect, case, status) sets are identical, so the repin and the renderer change introduced no new divergence (including for the size-16 and screenDivide/zoom destination cases the renderer change touches). Per the publication policy the raw gate log and sweep reports are retained in the supervisor's archived job evidence (Worker Elves job `6e194787-c477-4318-8bbf-84fdc83fa4d6`, files `parity-default-gate-a8f1ffe-code.log` and `sweep-a8f1ffe/` incl. `TOTAL.txt`: cases=1625 exact=1607 nonexact=18) rather than regenerated under `docs/evidence/`.

Provenance and machine-checkability of these numbers: the default-gate result at the new pin is machine-checked in-repo by [export-kit.yml](../.github/workflows/export-kit.yml)'s parity job, which runs `scripts/parity.rb` against the oracle checked out at the `scripts/oracle-lock.json` revision on every push to `main` (Actions run 36393070099 at `a8f1ffe`, whose code is identical to this record's scope, passed). The extended-sweep counts above were executed by the sync job itself (Worker Elves job `6e194787-c477-4318-8bbf-84fdc83fa4d6`) against a clean checkout of the pinned revision; the repository's publication policy keeps raw sweep output out of `docs/evidence/`, and this job holds no workflow-change authority to add an in-repo automated sweep check, so these counts are backed by the supervisor's retained run artifacts (files `parity-default-gate-a8f1ffe-code.log` and `sweep-a8f1ffe/`, incl. `TOTAL.txt`: cases=1625 exact=1607 nonexact=18) rather than by a committed evidence file. They are independently reproducible with the committed harness at the pin: `NOISEMAKER_CPU_DIR=<clean checkout of the scripts/oracle-lock.json revision> ruby scripts/parity-sweep.rb --shard <0..5>/6 --report <path>` and `--merge`. Full parity remains unverified until the 13 diverging effects are corrected and re-swept at the then-current pin.

### GAP-001 qualification, 2026-09-26

The locked 205-effect comparator ran at the pinned authority `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` (upstream `2f47612c29045c1b91af94887a8ff20106e980ef`, verified clean checkout) after integrating upstream commit `91ae3f6`. Default gate (one scene per effect, size 8, seed 1, time 0.25): 205 of 205 byte-exact on Ruby 3.2.8 ([raw log](evidence/gap-001/parity-default-ruby-3.2.8.log)) and on Ruby 3.4.5 (see [sweep report](evidence/gap-001/parity-sweep-report.json)). Extended sweep ([raw report](evidence/gap-001/parity-sweep-report.json), [summary](evidence/gap-001/parity-evidence-summary.json)) on Ruby 3.4.5 executed 1625 byte-exact-RGBA8 cases across all 205 effects: default, up to 3 nondefault-parameter cases per effect (560 executed; 922 parameters excluded with reasons recorded in the report), animation times 0.0/1.0, iterated state (iterationCount 3), seed 7, 16x16 scenes, and volumeSize 8 for volume effects. 1607 cases are exact. 17 cases across 13 effects differ (maxdiff 1-255) and synth/testPattern with pattern=colorBars raises a Ruby runtime error ("can't convert Array into Float"). Those effects are marked in the inventory below; the per-case parameters, exclusions, errors, and PNG source hashes are in the committed report. The committed report is the output of the committed harness run in `--merge` mode — its header records the full merge invocation — and the `--merge` mode is part of the committed script; it records every run's report path, ruby version, HEAD, and dirtiness. The per-run `command` fields inside the shard reports record the bare invocation `ruby scripts/parity-sweep.rb` because an option-parsing bug dropped arguments before the field was written; the committed harness corrects this (`raw_command` captured before option parsing, hash in the summary). Each run was executed on a clean tree at pre-publication HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc` (recorded in every run header with `git_dirty: false`), and the published candidate adds only evidence files outside the harness source-hash globs, so the report's `candidate.source_hashes` are identical at that HEAD and at this commit. Full parity remains unverified until the 13 effects are corrected and re-swept.

### Daily review, 2026-09-25

Exact-source CI reports 205 of 205 default CPU cases byte-exact. Its integration test log reports 229 runs, 1,426 assertions, and six skips. Standalone variants retain 24 skips. Five current effect IDs and broader parameters, state, platforms, and installed workflows remain unqualified. This is bounded evidence, not full parity. Raw CI log for Actions run 36076250675 (retained by the operator review — exact-source Actions are linked above).

The current full case denominator remains incomplete. Missing parameters, hosts, external inputs, and stateful sequences remain qualification gaps. No skip or tolerated difference counts as exact parity.

### Earlier measurements

Full parity requires complete applicable coverage with no skips or missing cases.
Historical NEAR, CHAOS, and tolerated differences do not count as strict equality.
The existing numerical contracts remain separate from exact comparison. This report does not change tolerances or goldens.
Unknown values mean `not measured`, never zero.

| Gate | Expected cases | Executed | Strict passes | Failures | Skips | Status |
|---|---|---|---|---|---|---|
| Default gate, 2026-09-28 re-run | 205 | 205 | 205 byte-exact (Ruby 3.4.5) | 0 | 0 | fresh execution, exit 0 |
| Current full render suite | 205 effects / 1625 sweep cases | 205 / 1625 | 205 default gate byte-exact (Ruby 3.2.8 and 3.4.5). 1607 of 1625 sweep cases | 17 sweep cases differ across 13 effects, 1 Ruby runtime error | 0 | default gate exact. Extended sweep found defects (see above) |
| Pinned JavaScript effect sweep | 205 | 205 | 205 | 0 | 0 | bounded sweep passed at historical authority, superseded by the 2026-09-26 runs above |

The current catalog manifest holds 210 effect IDs. The bundle and the pinned oracle inventory both hold 205 IDs.
The five manifest IDs outside the bundle are `render/meshLoader`, `render/meshRender`, `synth/roll`, `synth/scope`, `synth/spectrum`.
The port and the JavaScript oracle both exclude them, so no executable case exists for them in this contract.
They remain missing cases toward the 210-ID authority. They do not become successful tests.

Current served declaration: 205 effect IDs, equal to the bundle. This inventory is not evidence of execution. The declaration column below reflects kit `0.1.9`.

### Effect inventory

| Effect ID | Declared in served kit | Current full parity |
|---|---|---|
| `classicNoisedeck/bitEffects` | yes | default + extended sweep exact |
| `classicNoisedeck/caustic` | yes | default + extended sweep exact |
| `classicNoisedeck/cellNoise` | yes | default + extended sweep exact |
| `classicNoisedeck/cellRefract` | yes | default + extended sweep exact |
| `classicNoisedeck/coalesce` | yes | default + extended sweep exact |
| `classicNoisedeck/colorLab` | yes | default + extended sweep exact |
| `classicNoisedeck/composite` | yes | default + extended sweep exact |
| `classicNoisedeck/effects` | yes | default + extended sweep exact |
| `classicNoisedeck/fractal` | yes | default + extended sweep exact |
| `classicNoisedeck/glitch` | yes | default + extended sweep exact |
| `classicNoisedeck/kaleido` | yes | default + extended sweep exact |
| `classicNoisedeck/lensDistortion` | yes | default + extended sweep exact |
| `classicNoisedeck/moodscape` | yes | default + extended sweep exact |
| `classicNoisedeck/noise` | yes | default + extended sweep exact |
| `classicNoisedeck/noise3d` | yes | differs off-default (param-type, maxdiff 112) |
| `classicNoisedeck/refract` | yes | default + extended sweep exact |
| `classicNoisedeck/shapeMixer` | yes | default + extended sweep exact |
| `classicNoisedeck/shapes` | yes | default + extended sweep exact |
| `classicNoisedeck/shapes3d` | yes | default + extended sweep exact |
| `classicNoisedeck/splat` | yes | default + extended sweep exact |
| `filter/adjust` | yes | default + extended sweep exact |
| `filter/bloom` | yes | default + extended sweep exact |
| `filter/blur` | yes | default + extended sweep exact |
| `filter/bulge` | yes | default + extended sweep exact |
| `filter/celShading` | yes | default + extended sweep exact |
| `filter/channel` | yes | default + extended sweep exact |
| `filter/chroma` | yes | default + extended sweep exact |
| `filter/chromaticAberration` | yes | default + extended sweep exact |
| `filter/chrome` | yes | default + extended sweep exact |
| `filter/clouds` | yes | default + extended sweep exact |
| `filter/colorReplace` | yes | default + extended sweep exact |
| `filter/convolutionFeedback` | yes | default + extended sweep exact |
| `filter/corrupt` | yes | default + extended sweep exact |
| `filter/craquelure` | yes | differs off-default (size-16, maxdiff 1) |
| `filter/crt` | yes | default + extended sweep exact |
| `filter/degauss` | yes | default + extended sweep exact |
| `filter/deriv` | yes | default + extended sweep exact |
| `filter/directionalBlur` | yes | default + extended sweep exact |
| `filter/dither` | yes | default + extended sweep exact |
| `filter/edge` | yes | default + extended sweep exact |
| `filter/emboss` | yes | default + extended sweep exact |
| `filter/extrude` | yes | default + extended sweep exact |
| `filter/feedback` | yes | default + extended sweep exact |
| `filter/fibers` | yes | default + extended sweep exact |
| `filter/flipMirror` | yes | default + extended sweep exact |
| `filter/fxaa` | yes | default + extended sweep exact |
| `filter/glowingEdge` | yes | default + extended sweep exact |
| `filter/glyphMap` | yes | default + extended sweep exact |
| `filter/grade` | yes | default + extended sweep exact |
| `filter/grain` | yes | default + extended sweep exact |
| `filter/grime` | yes | default + extended sweep exact |
| `filter/halftone` | yes | default + extended sweep exact |
| `filter/hatch` | yes | default + extended sweep exact |
| `filter/highPass` | yes | default + extended sweep exact |
| `filter/historicPalette` | yes | default + extended sweep exact |
| `filter/invert` | yes | default + extended sweep exact |
| `filter/lens` | yes | default + extended sweep exact |
| `filter/lensFlare` | yes | default + extended sweep exact |
| `filter/lensWarp` | yes | default + extended sweep exact |
| `filter/lightLeak` | yes | default + extended sweep exact |
| `filter/lighting` | yes | default + extended sweep exact |
| `filter/lowPoly` | yes | default + extended sweep exact |
| `filter/median` | yes | differs off-default (param-radius, maxdiff 128) |
| `filter/morphology` | yes | default + extended sweep exact |
| `filter/mosaicTiles` | yes | default + extended sweep exact |
| `filter/motionBlur` | yes | default + extended sweep exact |
| `filter/normalMap` | yes | default + extended sweep exact |
| `filter/normalize` | yes | default + extended sweep exact |
| `filter/octaveWarp` | yes | default + extended sweep exact |
| `filter/oilPaint` | yes | default + extended sweep exact |
| `filter/osd` | yes | default + extended sweep exact |
| `filter/outline` | yes | default + extended sweep exact |
| `filter/palette` | yes | default + extended sweep exact |
| `filter/parallax` | yes | default + extended sweep exact |
| `filter/patchwork` | yes | default + extended sweep exact |
| `filter/photocopy` | yes | default + extended sweep exact |
| `filter/pinch` | yes | default + extended sweep exact |
| `filter/pixelSort` | yes | default + extended sweep exact |
| `filter/pixels` | yes | default + extended sweep exact |
| `filter/plasticWrap` | yes | default + extended sweep exact |
| `filter/polar` | yes | default + extended sweep exact |
| `filter/pondRipples` | yes | default + extended sweep exact |
| `filter/posterize` | yes | default + extended sweep exact |
| `filter/prismaticAberration` | yes | default + extended sweep exact |
| `filter/reindex` | yes | default + extended sweep exact |
| `filter/relief` | yes | default + extended sweep exact |
| `filter/repeat` | yes | default + extended sweep exact |
| `filter/reverb` | yes | default + extended sweep exact |
| `filter/ridge` | yes | default + extended sweep exact |
| `filter/rotate` | yes | default + extended sweep exact |
| `filter/scale` | yes | default + extended sweep exact |
| `filter/scanlineError` | yes | default + extended sweep exact |
| `filter/scatter` | yes | default + extended sweep exact |
| `filter/scratches` | yes | default + extended sweep exact |
| `filter/scroll` | yes | default + extended sweep exact |
| `filter/seamless` | yes | default + extended sweep exact |
| `filter/sharpen` | yes | default + extended sweep exact |
| `filter/simpleAberration` | yes | default + extended sweep exact |
| `filter/sine` | yes | default + extended sweep exact |
| `filter/skew` | yes | default + extended sweep exact |
| `filter/smooth` | yes | default + extended sweep exact |
| `filter/smoothstep` | yes | default + extended sweep exact |
| `filter/snow` | yes | default + extended sweep exact |
| `filter/sobel` | yes | default + extended sweep exact |
| `filter/spatter` | yes | default + extended sweep exact |
| `filter/spinBlur` | yes | default + extended sweep exact |
| `filter/spiral` | yes | default + extended sweep exact |
| `filter/spookyTicker` | yes | differs off-default (seed/time/size cases, maxdiff 63-102) |
| `filter/stamp` | yes | default + extended sweep exact |
| `filter/step` | yes | default + extended sweep exact |
| `filter/stipple` | yes | default + extended sweep exact |
| `filter/strayHair` | yes | default + extended sweep exact |
| `filter/strokes` | yes | default + extended sweep exact |
| `filter/temporalAberration` | yes | default + extended sweep exact |
| `filter/tetraColorArray` | yes | default + extended sweep exact |
| `filter/tetraCosine` | yes | default + extended sweep exact |
| `filter/text` | yes | default + extended sweep exact |
| `filter/texture` | yes | default + extended sweep exact |
| `filter/threshold` | yes | default + extended sweep exact |
| `filter/tile` | yes | default + extended sweep exact |
| `filter/tint` | yes | default + extended sweep exact |
| `filter/translate` | yes | default + extended sweep exact |
| `filter/tunnel` | yes | default + extended sweep exact |
| `filter/unsharpMask` | yes | default + extended sweep exact |
| `filter/vaseline` | yes | default + extended sweep exact |
| `filter/vignette` | yes | default + extended sweep exact |
| `filter/warp` | yes | default + extended sweep exact |
| `filter/watercolor` | yes | default + extended sweep exact |
| `filter/waves` | yes | default + extended sweep exact |
| `filter/wind` | yes | default + extended sweep exact |
| `filter/wobble` | yes | default + extended sweep exact |
| `filter/wormhole` | yes | default + extended sweep exact |
| `filter/zoomBlur` | yes | default + extended sweep exact |
| `filter3d/flow3d` | yes | default + extended sweep exact |
| `filter3d/palette3d` | yes | default + extended sweep exact |
| `mixer/alphaMask` | yes | default + extended sweep exact |
| `mixer/applyMode` | yes | default + extended sweep exact |
| `mixer/blendMode` | yes | default + extended sweep exact |
| `mixer/cellSplit` | yes | default + extended sweep exact |
| `mixer/centerMask` | yes | default + extended sweep exact |
| `mixer/channelCombine` | yes | default + extended sweep exact |
| `mixer/distortion` | yes | default + extended sweep exact |
| `mixer/focusBlur` | yes | default + extended sweep exact |
| `mixer/mashup` | yes | default + extended sweep exact |
| `mixer/patternMix` | yes | default + extended sweep exact |
| `mixer/shadow` | yes | default + extended sweep exact |
| `mixer/shapeMask` | yes | differs off-default (param-shape, maxdiff 128) |
| `mixer/split` | yes | default + extended sweep exact |
| `mixer/thresholdMix` | yes | default + extended sweep exact |
| `mixer/uvRemap` | yes | default + extended sweep exact |
| `points/attractor` | yes | default + extended sweep exact |
| `points/buddhabrot` | yes | default + extended sweep exact |
| `points/dla` | yes | differs off-default (size-16, maxdiff 1) |
| `points/flock` | yes | default + extended sweep exact |
| `points/flow` | yes | default + extended sweep exact |
| `points/heightGrid` | yes | default + extended sweep exact |
| `points/hydraulic` | yes | default + extended sweep exact |
| `points/lenia` | yes | default + extended sweep exact |
| `points/life` | yes | default + extended sweep exact |
| `points/physarum` | yes | default + extended sweep exact |
| `points/physical` | yes | default + extended sweep exact |
| `render/loopBegin` | yes | default + extended sweep exact |
| `render/loopEnd` | yes | default + extended sweep exact |
| `render/meshLoader` | no | missing from bundle and oracle inventory; never executed |
| `render/meshRender` | no | missing from bundle and oracle inventory; never executed |
| `render/pointsBillboardRender` | yes | differs off-default (param-blendMode, maxdiff 128) |
| `render/pointsEmit` | yes | default + extended sweep exact |
| `render/pointsRender` | yes | default + extended sweep exact |
| `render/render3d` | yes | differs off-default (param-filtering, maxdiff 142) |
| `render/renderCubemap3d` | yes | differs off-default (param-filtering, maxdiff 129) |
| `render/renderCubemapSurface` | yes | default + extended sweep exact |
| `render/renderLandscape3d` | yes | default + extended sweep exact |
| `render/renderLit3d` | yes | default + extended sweep exact |
| `synth/bitwise` | yes | default + extended sweep exact |
| `synth/cell` | yes | default + extended sweep exact |
| `synth/cellularAutomata` | yes | default + extended sweep exact |
| `synth/curl` | yes | default + extended sweep exact |
| `synth/gabor` | yes | default + extended sweep exact |
| `synth/gradient` | yes | differs off-default (param-rotation, maxdiff 1) |
| `synth/julia` | yes | default + extended sweep exact |
| `synth/mandala` | yes | default + extended sweep exact |
| `synth/mandelbrot` | yes | differs off-default (param-outputMode, maxdiff 249) |
| `synth/media` | yes | default + extended sweep exact |
| `synth/mnca` | yes | default + extended sweep exact |
| `synth/modPattern` | yes | default + extended sweep exact |
| `synth/navierStokes` | yes | default + extended sweep exact |
| `synth/newton` | yes | default + extended sweep exact |
| `synth/noise` | yes | default + extended sweep exact |
| `synth/osc2d` | yes | default + extended sweep exact |
| `synth/pattern` | yes | default + extended sweep exact |
| `synth/perlin` | yes | default + extended sweep exact |
| `synth/polygon` | yes | default + extended sweep exact |
| `synth/reactionDiffusion` | yes | default + extended sweep exact |
| `synth/remap` | yes | default + extended sweep exact |
| `synth/roll` | no | missing from bundle and oracle inventory; never executed |
| `synth/sacredGeometry` | yes | default + extended sweep exact |
| `synth/scope` | no | missing from bundle and oracle inventory; never executed |
| `synth/shape` | yes | default + extended sweep exact |
| `synth/solid` | yes | default + extended sweep exact |
| `synth/spectrum` | no | missing from bundle and oracle inventory; never executed |
| `synth/subdivide` | yes | default + extended sweep exact |
| `synth/testPattern` | yes | Ruby error on param-pattern (colorBars); size-16 differs (maxdiff 255) |
| `synth3d/cell3d` | yes | default + extended sweep exact |
| `synth3d/cellularAutomata3d` | yes | default + extended sweep exact |
| `synth3d/flythrough3d` | yes | differs off-default (param-power, maxdiff 13) |
| `synth3d/fractal3d` | yes | default + extended sweep exact |
| `synth3d/heightmap3d` | yes | default + extended sweep exact |
| `synth3d/noise3d` | yes | default + extended sweep exact |
| `synth3d/reactionDiffusion3d` | yes | default + extended sweep exact |
| `synth3d/shape3d` | yes | default + extended sweep exact |

## 4. Evidence

Audit 2026-09-28 commands, exit codes, and results are recorded in [completion gaps](COMPLETION_GAPS.md#methods-and-evidence), section 3. Raw results live in the shared series store at `/series/evidence-audit-20260928-035500/` (not committed to this repository).
Official ecosystem reference: [Current RubyGems guide, accessed 2026-09-24](https://guides.rubygems.org/make-your-own-gem/).
Source CI, export dispatch, artifact delivery, and rendered parity are separate evidence dimensions.
A successful dispatch or unit-test summary does not establish a full rendered gate.

Exact-source CI at runtime commit `91ae3f6` ([run 36256396160](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/36256396160)) passed all jobs.
The pinned parity leg reported 205/205 byte-exact. Integration tests reported 229 runs, 1,426 assertions, and six skips. Standalone matrix jobs each reported 24 skips.
`lib`, `exe`, and tests are identical at `91ae3f6` and the inspected source `b02f816`, so that run is exact-source evidence for the shipped runtime.
No CI ran at `b02f816`: its push paths filter `['**', '!*.md', '!docs/**', '!.github/ISSUE_TEMPLATE/**', '!.github/PULL_REQUEST_TEMPLATE*', '!.github/CODEOWNERS', '!.editorconfig', 'README.md']` excludes these documentation paths, so the audit publication triggers no workflow and no export-kit dispatch.

Publication CI at `b4d7cdda69967db15dd2adb69ea9cf5b5381e843` passed. The pinned JavaScript effect sweep passed all 205 cases byte-for-byte.
This result covers the declared sweep at its pinned authority. It does not prove all current-authority parameters, inputs, states, or host combinations.
Required integration tests reported 226 runs, 1,401 assertions, and six skips. Standalone matrix jobs each reported 24 skips.
These skips remain qualification gaps. The documentation-only update did not dispatch an artifact release.
[Exact publication CI](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/35959915028).
Raw CI evidence: ruby-final-ci.log (operator-retained, not committed to this repository).

## 5. Open compatibility limits

GAP-001 closed on 2026-09-29: the 13 diverging effects are corrected, the whole-port gate is 205/205 byte-exact at the pinned authority, and the extended 1625-case grid is byte-exact at the corrected tree. Its scope is the 205 bundled effect IDs; the five non-bundled authority-manifest IDs remain missing toward 210.
Next bounded checks live in the [current status list](COMPLETION_GAPS.md#5-ordered-next-actions).
See [GAP-001 and the complete gap register](COMPLETION_GAPS.md#4-known-gaps) for evidence, dependencies, and acceptance criteria.

1. ~~GAP-001: correct the 13 diverging effects.~~ Done 2026-09-29 (GAP-001 closed). Keep its evidence current whenever the runtime, transpiler, or pin changes.
2. GAP-003: the owner decides the `rubygems.org` publication path. After a published version exists, run an isolated upgrade test.
3. GAP-003: run the Windows platform checks when a Windows host is available.
4. Keep GAP-002 evidence current whenever entry points change.

All eligible ports have equal priority. Zero missing executable cases toward the 210-ID authority and zero skipped cases remain the goal.
Implementation corrections remain with the separate job. This report does not advance the parity checkpoint.

## 6. History

2026-09-25 daily review at `d7942883e2e56486dd6c186486cd794cc3a512a4`: source freshness and bounded evidence reviewed. Open qualification limits retained. Retained review evidence: Actions run 36076250675 (retained by the operator review — exact-source Actions are linked above). No new closure claimed.

| Date | Source | Result | Change |
|---|---|---|---|
| 2026-09-28 | `b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8` | Default gate re-verified by fresh execution (205/205 byte-exact). GAP-002 closed for the qualified matrix. | Served kit `0.1.9` byte-verified in full. Five false inventory rows corrected. Installed workflow, error recovery, and removal verified on Linux Ruby 3.4.5. |
| 2026-09-26 | this commit | Extended qualification | Ran the locked 205-effect comparator at the pinned authority with the extended sweep (1625 cases). Default gate exact; 17 cases across 13 effects differ off-default; one Ruby runtime error. Evidence committed under [evidence/gap-001](evidence/gap-001/parity-evidence-summary.json). GAP-001 remains open. |
| 2026-09-24 | `379aa03df26df8b17f6916535c83328bb0e8eaa3` | Full qualification unverified | Created the requested maintained compatibility report. Preserved historical evidence and open gaps. |

Publication follow-up: recorded exact-source CI and retained every observed skip. No gap was closed.

Run: `audit-20260928-035500`. Earlier runs: `20260924-remaining-gap-documents`, the 2026-09-25 daily review, and the 2026-09-26 extended qualification. Later audits and reviews update this report with source-bound results.
