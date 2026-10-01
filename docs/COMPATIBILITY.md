# noisemaker-for-ruby: compatibility report

## 1. Source and authority revisions

Scheduled audit: 2026-09-28. Current inspected source: [`b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8). Local `main` matched remote before checks. Checkout clean.
Full rendered parity is partial. GAP-001 is open: 205 of the 210 authority-manifest IDs are byte-exact at the pinned authority. The five non-bundled IDs have no executable case because the pinned oracle does not implement them. No release approval follows from this audit.
Pinned authority: CPU `116dae317a07a96d9f8ef3b0320f873871ff6b57`, upstream `e24c844f8dada85551ab084f41db8944fbc176c8` (lock repinned by sync commit for the delivered range `d6664f8a494a..116dae317a07`; the previous pin `d6664f8a494aec3bd10bce200d63d42ec833d61a` / upstream `e24c844f8dada85551ab084f41db8944fbc176c8` was set by the 2026-10-01 sync, earlier `50c1cbe3319158be9d2965ebd4934b2852d96789` / upstream `e24c844f8dada85551ab084f41db8944fbc176c8` by the 2026-10-01 sync, earlier `5f12866e919f76fc19e4d3e6f0670d61d10dc672` / upstream `e24c844f8dada85551ab084f41db8944fbc176c8` by the 2026-09-30 sync, earlier `d2965d0b7880cee678de11ec797155c8a65c7b66` / upstream `f24b52540af6a88d12daa05feba1a04ad61b22a2` by the 2026-09-29 sync, earlier `fd9d56c74ce7` / `73c15be0`, earlier `bfbe54764eee` / `8eeb7b5a` by sync `a8f1ffe`, earlier `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / `2f47612c`). Measured results below from the 2026-09-28 scheduled audit bind the earlier pin `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c`; later results are recorded in "Post-repin requalification, 2026-09-28", "Delivered-range audit, 2026-09-29 (sync to `fd9d56c74ce7`)", "Delivered-range audit, 2026-09-29 (sync to `d2965d0b7880`)", "Delivered-range audit, 2026-09-30 (sync to `5f12866e919f`)", "Delivered-range audit, 2026-10-01 (sync to `50c1cbe3319`)", "Delivered-range audit, 2026-10-01 (sync to `d6664f8a494a`)" and "Delivered-range audit, 2026-10-01 (sync to `116dae317a07`)" in section 3 and bind their own pins.
Current CPU authority head: `116dae317a07a96d9f8ef3b0320f873871ff6b57` — the pin (delivered-range audit below, 2026-10-01).
Upstream discovery: `e24c844f8dada85551ab084f41db8944fbc176c8`. CDN `/1.0/` manifest SHA-256 `05c4d7b7744837ae90a3bb4c89e5403ff09448a74d9d7e824abb3d719ad3314e` is unchanged and holds 210 effect IDs.
Current served kit: `0.1.13`, source `e9c4f12fd2e3fa4b353edcd981702438bf9396da`. All 329 served files match the inventory hashes. 325 files are byte-identical to that source.
`rubygems.org` returns 404 for this package. Distribution is build-from-checkout plus the export kit. GAP-003 closed for this existing distribution on 2026-09-29 after the published `0.1.9` → `0.1.13` consumer upgrade on Ruby 4.0.5 Darwin arm64; Windows remains unqualified. [Commands and results](COMPLETION_GAPS.md#gap-003-distribution-and-release-qualification).

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
| Supported operating systems and backends | verified (Linux local and CI, macOS CI) | Windows unmeasured: no Windows host and no workflow-change grant for a hosted Windows runner leg in this harness. |
| Installed package and first useful result | verified | 2026-09-28: built gem installed in an isolated `GEM_HOME`. First render, filter, and DSL output pass. |
| Parameters, external inputs, state, and chains | passed (1625/1625 cases byte-exact) | Extended sweep covered parameters, seeds, sizes, times, state, and volumes at the pinned authority. The 17 previously differing cases across 13 effects and the colorBars runtime error are corrected (commits `6591842c`, `2b161d0a`, `e9c4f12f`); the whole-port PARITY-SUMMARY at the published candidate is 205/205 exact and the extended grid is byte-exact at the corrected tree (raw reports archived with the job evidence). |
| Invalid input and recovery | verified | 2026-09-28: invalid effect and parameter name the effect and parameter, exit 2, and corrected input renders. |
| Cancellation and file preservation | verified (isolated install) | 2026-09-28: SIGINT mid-render exits at once. An existing output file stays byte-identical, and frames written before the interrupt are retained. Cancelled runs print a raw Ruby Interrupt trace. |
| Upgrade, removal, and resource cleanup | verified for existing distribution | 2026-09-29: published kit `0.1.9` → `0.1.13` consumer upgrade on Ruby 4.0.5 Darwin arm64; 329/329 files verified per version and after replacement, program renders byte-identically before/after, invalid-input recovery passes, consumer and download trees removed. Earlier isolated gem removal remains verified. [GAP-003 evidence](COMPLETION_GAPS.md#gap-003-distribution-and-release-qualification). |
| Accessibility of provided controls | verified (CLI diagnostics) | No graphical interface ships, so keyboard and focus checks are out of scope. |
| Release readiness | qualified for existing distribution | GAP-003 closed for the existing checkout/CDN channels and measured matrix. Parity covers 205 of 210 authority IDs; GAP-001 is open (five IDs have no executable case). RubyGems remains unpublished and Windows unqualified; no new release is approved. [GAP-003 evidence](COMPLETION_GAPS.md#gap-003-distribution-and-release-qualification). |

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

### Delivered-range audit, 2026-09-29 (sync to `fd9d56c74ce7`; forced, non-contiguous delivery)

The nine observed delivery ranges (`64d7ea4..9683091`, `9683091..7a82474`, `7a82474..dedfd07`, `dedfd07..34a0325`, `34a0325..b61b658`, `b61b658..f0ccebe`, `f0ccebe..f290040`, `f290040..21d211e`, `21d211e..fd9d56c`) were audited as their union `bfbe54764eee87c8f67d2b281d5f304faad04a5b..fd9d56c74ce7500b7eaeea90a93d3bf49375d28e` in a fresh `--filter=blob:none` clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git (37 commits; 32 files changed, +3094/−102); every observed range endpoint is inside that union. Per-file mapping to this port (machine-checkable register: archived evidence `range-audit-fd9d56c/file-mapping.json`, sha256 `dce64ef2c268c6129fc05c40bda0f09ae704acf8e239f5c2c3a7d158ef62f1e3`, one entry per changed file in `union-files.txt`):

- `scripts/upstream/source-lock.js`, `scripts/upstream/pinned-source-manifest.json`, `src/effects/generated/upstream-snapshot.js` — the upstream pin moved `8eeb7b5a`→`73c15be0` with a new pinned-source digest `b78f27e21703a5ae3f976273e946f71b435193eeee4006c98caba229e3eedcaa`. The upstream range (`8eeb7b5a..73c15be0`) touches no `shaders/effects` file; it adds editor/preflight/runtime instrumentation only (`predictReplacement` in `lang/transform.js`, `getParamAliases` in `paramAliases.js`, `runtime/backends/diagnostics.js`, `runtime/preflight.js`, and pipeline/webgl2/webgpu diagnostics hooks). The effect-shader set the bundle kernels hash is unchanged, so the committed bundle and `bundle-lock.json` remain valid unchanged. Mirrored by repinning `scripts/oracle-lock.json` to CPU `fd9d56c74ce7` / upstream `73c15be0` / digest `b78f27e2…` and bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.
- `scripts/parity/run.js`, `scripts/parity/write-provenance.js`, `parity/goldens/provenance.json` — reference-capture provenance reporting for the CPU repo's own committed-golden gate (separating capture provenance from the candidate pin, and wording the 20 volume/loop skips). The port's authority contract executes the pinned runtime's manifest directly rather than committed captures; nothing to port.
- `examples/browser/*` (distinct accessible names for the browser demo controls): browser-demo surface; the headless port has no DOM canvas and no rendered-output behavior to port — consistent with the `CanvasSink` treatment in the audit above.
- `package.json` — adds CPU-side docs to the npm published-file list; no npm publication exists for this port.
- `test/cpu-special-effects.test.js`, `test/demo-pipeline.test.js`, `test/parity-golden-provenance.test.js`, `test/upstream-inventory.test.js` — CPU-side tests (provenance suite, demo pipeline, updated inventory revision string); the port's equivalents are the oracle-present minitest suite and the PARITY-SUMMARY gate below.
- `docs/*`, `README.md`, `landscape-authority-comparison.json`, `parity.log`, `probe.json`, `docs/evidence/*` — CPU-side audit records and evidence; not mirrored beyond this register.

Binding evidence at the new pin: whole-port `./scripts/parity-summary` (oracle provisioned at the lock revision `fd9d56c74ce7`) reports PARITY-SUMMARY {"expected":205,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":0}, exit 0, on the unchanged 205-ID scope — confirming the delivered range introduces no rendered-output change; standalone suite 230 runs, 0 failures, 24 skips, and the oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `fd9d56c74ce7`) 230 runs, 0 failures, 7 skips including the executed-and-passing pin binding `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity` (run separately with `--verbose`: 1 run, 6 assertions, 0 failures, 0 skips). Run logs are archived with the job evidence: `range-audit-fd9d56c/` holds `suite-standalone.log` (sha256 `ba7c0eca22ba93bb016221b29f6b28ae08ec473085dac72e1ef612eaab9a3e26`), `suite-oracle.log` (`82ea076c2e069a40fa7aa3a9dcab6c0cb14c6c9112c41f61b1d1545161250182`), `binding-test.log` (`e4ba7886f360b49b6cc89d9e85e3ae993722e20afe7dd072bb63fb069b635d6f`), `parity-summary.log` (`15ca907ee22659b60a2913e3d6200cb434f6994b78a28f5f2918163012862d38`), the union-audit raw artifacts `union-log.txt` (`39eef265ae72840126f1a02589f4436b981a3e2e8b2dc2e326367c82dc343d92`), `union-files.txt` (`30e3f513a298a4e1728cfded4efc6edf13802a9bc1f6fa9eef6c96bff2617b60`), `union-numstat.txt` (`043de377d008bb7e0a185f94d9e9a9a37e244697a15ea61ee1e8ad3a12d71cd5`, "3094 insertions, 102 deletions, 32 files"), `union-blobs.json` (`60fd4a558c81615dd3bead19a3a795389d65307479e42e09c89c867752af2bc9`, per-file before/after blob and content sha256 for all 32 files), `shaders-diff-empty.txt` (`9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa`, `0`), and a `SHA256SUMS` manifest; the per-endpoint ancestry checks (`git merge-base --is-ancestor` of the old pin and every observed range endpoint against the union head) all passed. The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### Delivered-range audit, 2026-09-29 (sync to `d2965d0b7880`)

The delivered range `fd9d56c74ce7500b7eaeea90a93d3bf49375d28e..d2965d0b7880cee678de11ec797155c8a65c7b66` was flagged as force-pushed/non-contiguous, but in a full clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git `git merge-base --is-ancestor fd9d56c74ce7 d2965d0b7880` exits 0, so the range is contiguous and comprises 10 commits (machine-checkable audit: archived evidence `range-audit-d2965d0/`, with `commits.txt`, `log-numstat.txt` and `audit.json` under a `SHA256SUMS` manifest). Nine commits are CPU-side documentation/audit-record updates (docs/*, README.md) with nothing to port. The one code-touching commit, `d2965d0b7880`, is the upstream source-lock sync that repins the CPU repo's own pin `73c15be0`→`f24b5254` (upstream GAP-032 `AudioInputManager` multi-capture work, touching only `shaders/src/runtime/external-input.js` and upstream tests):

- `shaders/` is byte-identical across the range (`git diff fd9d56c74ce7 d2965d0b7880 -- shaders/effects shaders/src` is empty), and the generated snapshot `src/effects/generated/upstream-snapshot.js` changes only its `UPSTREAM_REVISION` line. The 205-effect catalog, parameter contracts and generated kernels are unchanged, so the committed Ruby bundle and the 205-ID parity scope are unchanged.
- The new pinned-source digest `f11af18a15ec0220c5d41a17c70da637fa05f86597a4c1984838bd0e77246723` was independently recomputed (not copied) by running the CPU checkout's `computePinnedSourceDigest`/`computeSourceManifest`/`sourceManifestDigest` with node against a fresh `--filter=blob:none` clone of noisefactorllc/noisemaker checked out at `f24b5254`: digest, manifest digest `143497d9db7c06955057c925c1b1f2fdb29dd8120ce9f5b2d9fa0be6fbc786a6`, 1132 manifest entries, and the single changed entry `shaders/src/runtime/external-input.js` (54120→67725 bytes, sha256 `c29887aa…`) all match the CPU pin exactly. The Ruby port has no WebAudio/audio-input runtime (grep `AudioInputManager|external-input` over `lib/`, `exe/`, `scripts/`, `test/`, `export-kit/` matches nothing), so no Ruby behavioral change applies.
- Mirrored by repinning `scripts/oracle-lock.json` to CPU `d2965d0b7880` / upstream `f24b5254` / digest `f11af18a…`, bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.

Binding evidence at the new pin: standalone suite 230 runs, 0 failures, 24 skips; oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `d2965d0b7880`) 230 runs, 0 failures, 7 skips, including the executed-and-passing pin binding (run separately with `--verbose`: 18 runs, 50 assertions, 0 failures, 6 CDN-live skips); whole-port `./scripts/parity-summary` reports PARITY-SUMMARY {"expected":205,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":0}, exit 0, both standalone and inside the oracle-present suite. Run logs are archived with the job evidence under `range-audit-d2965d0/`: `suite-standalone.log` (sha256 `cd21690b86e2277fe4bc5de98289e36f1702398f4440161dd25f9ed3b07cbf81`, includes the whole-port gate), `suite-oracle.log` (`aa3904bcb8c5fcb57531e4083ea58ca426c068eb6de5d23759de730e81659ceb`), `binding-test.log` (`270a52e1001e2f8e167099b3e817250f5643e74e725f8740a2882210b20b1c46`), `commits.txt` (`1df69364152af714b4885d2074c4d7d700c259cda444ed9524f8e1b93a32e761`), `log-numstat.txt` (`2b233bc2014f6296791498570590c450d7ced59893ae00e851d0c377c7df338c`), `audit.json` (`50246dec717ca07156694adbb387274ea952f7563a48748ab1d3ed5ed64ab0f9`). The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### Delivered-range audit, 2026-09-30 (sync to `5f12866e919f`)

The delivered range `d2965d0b7880cee678de11ec797155c8a65c7b66..5f12866e919f76fc19e4d3e6f0670d61d10dc672` (7 commits since the previous pin; the job's flagged start `fd9d56c74ce7..5f12866e919f` spans 17 commits and the flag was audited: in a full clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git `git merge-base --is-ancestor fd9d56c74ce7 5f12866e919f` exits 0, so the flagged range is contiguous — machine-checkable audit: archived evidence `range-audit-5f12866/`, with `commits.txt`, `log-numstat.txt`, `audit.json`, `shaders-diff-empty.txt` (empty) and a `SHA256SUMS` manifest). Six commits are CPU-side documentation/audit-record updates (docs/*, README) with nothing to port. The one code-touching commit, `5f12866e919f`, is the upstream source-lock sync that repins the CPU repo's own pin `f24b5254`→`e24c844f` for upstream GAP-007 backend-diagnostics work (upstream delta touches only `shaders/src/runtime/backends/diagnostics.js`, `webgl2.js`, `webgpu.js`, `shaders/src/runtime/pipeline.js` and upstream tests/docs):

- `shaders/` is byte-identical across the range (`git diff d2965d0b7880 5f12866e919f -- shaders/effects shaders/src` is empty), and the generated snapshot `src/effects/generated/upstream-snapshot.js` changes only its `UPSTREAM_REVISION` line. The 205-effect catalog, parameter contracts and generated kernels are unchanged, so the committed Ruby bundle and the 205-ID parity scope are unchanged.
- The new pinned-source digest `c2e0c264dc20338b19a144ee0888bd2ca39edcf325315a7d7ae1f5ced920804d` was independently recomputed (not copied) by running the CPU checkout's `computePinnedSourceDigest`/`computeSourceManifest`/`sourceManifestDigest` with node against a fresh clone of noisefactorllc/noisemaker checked out at `e24c844f`: digest, manifest digest `2516724e7d886253883107b60feff6b1da6ca8bc48186b05357c8443c56f1bff`, 1132 manifest entries, zero entry diffs against the CPU's committed manifest, and the four changed entries (`shaders/src/runtime/backends/diagnostics.js` 7128→8059 bytes, `backends/webgl2.js` 78150→81111, `backends/webgpu.js` 164220→164648, `runtime/pipeline.js` 123038→124928) all match the CPU pin exactly (archived `range-audit-5f12866/digest-recompute.json`). The headless Ruby port has no WebGL/WebGPU backend or pipeline runtime (no `WebGL`/`WebGPU` code paths in `lib/`, `exe/`), so no Ruby behavioral change applies.
- Mirrored by repinning `scripts/oracle-lock.json` to CPU `5f12866e919f` / upstream `e24c844f` / digest `c2e0c264…`, bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.

Binding evidence at the new pin: standalone suite 230 runs, 1250 assertions, 0 failures, 24 skips; whole-port `./scripts/parity-summary` (oracle provisioned at the lock revision `5f12866e919f`) reports PARITY-SUMMARY {"expected":210,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":5} — the five recorded non-bundled authority IDs lack oracle implementations, so `scripts/test` accepts exactly this recorded state, exit 0; the oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `5f12866e919f`, `NOISEMAKER_REQUIRE_ORACLE=1`) passes 230 runs, 1333 assertions, 0 failures, 7 skips, including the executed-and-passing pin binding (run separately with `--verbose`: 1 run, 6 assertions, 0 failures, 0 skips). Run logs are archived with the job evidence under `range-audit-5f12866/` (`suite-oracle.log` sha256 `fb0857ff3cc6724ce2899b22e441b922b696b2f51adc9ba05f16e7c39394c74d`, `binding-test.log` `e3c694520feff9cdb6da70514ed247db46710cef7e332181d7963dde5f450af8`, `digest-recompute.json` `95dd5935f17b6d8d967729566ac40c375f818e94bfd0246fcd1e14343311222d`, `audit.json` `2a153d7b51561177a11822f64a53fd3db6508f257864b42538ed1e454afad2de`, `commits.txt` `95ca2381c41d29b65be2fde1c1c9b4028110e936d5fbada9d8d70321ac27f7ea`, `log-numstat.txt` `965eafafa85f2ea9c7cd0b5025699a16b896e614fd9895382dc92a8bf1ee6fc7`, all under a `SHA256SUMS` manifest). The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### Delivered-range audit, 2026-10-01 (sync to `50c1cbe3319`)

The delivered range `5f12866e919f76fc19e4d3e6f0670d61d10dc672..50c1cbe3319158be9d2965ebd4934b2852d96789` (1 commit; the job's flagged start `fd9d56c74ce7..50c1cbe3319` was audited: in a full clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git `git merge-base --is-ancestor fd9d56c74ce7 50c1cbe3319` exits 0, and `fd9d56c74ce7` is itself an ancestor of the previous pin `5f12866e919f`, so the flagged range is contiguous — machine-checkable audit: archived evidence `range-audit-50c1cbe/`, with `commits.txt`, `log-numstat.txt`, `audit.json`, `shaders-diff.txt` (empty) and a `SHA256SUMS` manifest). The single commit, `50c1cbe3319`, is the CPU repo's own "GAP-003 first leg": it adds the CPU-side `scripts/parity-summary` entrypoint (`scripts/parity-summary`, `scripts/parity/summary.js`, `test/parity-summary.test.js`) and moves provenance helpers plus the shared skip-policy set from `scripts/parity/run.js` into `scripts/parity/lib.js`. No `shaders/effects` or `shaders/src` file changes (`git diff 5f12866e919f 50c1cbe3319 -- shaders/effects shaders/src` is empty), the generated snapshot `src/effects/generated/upstream-snapshot.js` is unchanged, and the CPU's upstream pin `e24c844f` and `PINNED_SOURCE_DIGEST` are unchanged — so the 205-effect catalog, parameter contracts, generated kernels, upstream source identity and the Ruby port's executable parity scope are all unchanged. This port already implements the same supervisor-runnable `scripts/parity-summary` contract entrypoint, so there is nothing to port.

- The pinned-source digest `c2e0c264dc20338b19a144ee0888bd2ca39edcf325315a7d7ae1f5ced920804d` was independently recomputed (not copied) by running the CPU checkout's `computePinnedSourceDigest` with node against a fresh clone of noisefactorllc/noisemaker checked out at `e24c844f`: the recomputed digest matches the CPU's recorded `PINNED_SOURCE_DIGEST` exactly (archived `range-audit-50c1cbe/digest-recompute.json`).
- Mirrored by repinning `scripts/oracle-lock.json` to CPU `50c1cbe3319` / upstream `e24c844f` / digest `c2e0c264…`, bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.

Binding evidence at the new pin: standalone suite 230 runs, 1250 assertions, 0 failures, 24 skips; whole-port `./scripts/parity-summary` (oracle provisioned at the lock revision `50c1cbe3319`) reports PARITY-SUMMARY {"expected":210,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":5} — the five recorded non-bundled authority IDs lack oracle implementations, so `scripts/test` accepts exactly this recorded state, exit 0; the oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `50c1cbe3319`, `NOISEMAKER_REQUIRE_ORACLE=1`) passes 230 runs, 1333 assertions, 0 failures, 7 skips, with the same accepted PARITY-SUMMARY line and exit 0. Run logs are archived with the job evidence under `range-audit-50c1cbe/` (`suite-default.log` sha256 `f3df217b8ef168d86d427945f3dd4f4a13fa181ee99b882b9d073f588f95badb`, `suite-oracle.log` `ed1c1723cc7309da4a1eb1a9f8cef1ec960f3e1e90eb97af72c82b647bd1372d`, `digest-recompute.json` `8982bf325eceb9ab5bf3e58aea2841cb4e15de11757a63a88429055feb28c1c1`, `audit.json` `8fdef7160ecad5a7fe10179c9916df84720260cb0b4bec798f660ca0ca458101`, `commits.txt` `c7009ceb22b61b77207099eeb6b84f2d7f21cd7dd01775f1a2701de363ae671a`, `log-numstat.txt` `3c4e810583c1cb084889b1ab371fe504a199695c7ee1af902c2e480e71fee4a5`, `shaders-diff.txt` `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty), all under a `SHA256SUMS` manifest). The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### Delivered-range audit, 2026-10-01 (sync to `d6664f8a494a`)

The delivered range `50c1cbe3319158be9d2965ebd4934b2852d96789..d6664f8a494aec3bd10bce200d63d42ec833d61a` (1 commit; the job's flagged start `fd9d56c74ce7..d6664f8a494a` was audited: in a full clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git `git merge-base --is-ancestor fd9d56c74ce7 d6664f8a494a` exits 0, and `fd9d56c74ce7` is itself an ancestor of the previous pin `50c1cbe3319`, so the flagged range is contiguous — machine-checkable audit: archived evidence `range-audit-d6664f8/`, with `commits.txt`, `log-numstat.txt`, `audit.json`, `shaders-diff.txt` (empty) and a `SHA256SUMS` manifest). The single commit, `d6664f8a494a`, is the CPU repo's own GAP-003 second leg: it updates the CPU repo's GAP-003 register row to identify the published CPU-side entrypoint and its honest-red counts, and hardens the CPU-side `scripts/parity/summary.js` (the `--tolerance` flag is locked to the CPU-side ±2 classification contract so a widened tolerance cannot count as passes) plus `test/parity-summary.test.js`, and adds a `referenceProvenance` aggregation to the CPU summary's PARITY-SUMMARY JSON with reference provenance on every emitted comparison line. No `shaders/effects` or `shaders/src` file changes (`git diff 50c1cbe3319 d6664f8a494a -- shaders/effects shaders/src` is empty), the generated snapshot `src/effects/generated/upstream-snapshot.js` and `scripts/upstream/source-lock.js` are unchanged, and the CPU's upstream pin `e24c844f` and `PINNED_SOURCE_DIGEST` are unchanged — so the 205-effect catalog, parameter contracts, generated kernels, upstream source identity and the Ruby port's executable parity scope are all unchanged.

- Nothing to port from the code change: this port's `scripts/parity-summary.rb` has no tolerance parameter at all — the published numerical contract here is byte-exact RGBA8, `strict` is always 0, and no widened tolerance can affect classification by construction; the tolerance-lock hardening is specific to the CPU-side summary's own ±2 contract. The `referenceProvenance` field is likewise CPU-side: this port renders its authority golden live through the pinned oracle at run time rather than retaining golden files, so there is no recorded-reference inventory to aggregate (CPU-side golden-provenance reporting was already recorded as intentionally not carried by the 2026-09-29 `fd9d56c74ce7` sync). The CPU docs edit updates the CPU repo's own GAP-003 register, whose local counterpart is this port's independent GAP-001 record — no row text carries over.
- The pinned-source digest `c2e0c264dc20338b19a144ee0888bd2ca39edcf325315a7d7ae1f5ced920804d` was independently recomputed (not copied) by running the CPU checkout's `computePinnedSourceDigest` with node against a fresh clone of noisefactorllc/noisemaker checked out at `e24c844f`: the recomputed digest matches the CPU's recorded `PINNED_SOURCE_DIGEST` exactly (archived `range-audit-d6664f8/digest-recompute.json`).
- Mirrored by repinning `scripts/oracle-lock.json` to CPU `d6664f8a494a` / upstream `e24c844f` / digest `c2e0c264…`, bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.

Binding evidence at the new pin: standalone suite 230 runs, 1250 assertions, 0 failures, 24 skips; whole-port `./scripts/parity-summary` (oracle provisioned at the lock revision `d6664f8a494a`) reports PARITY-SUMMARY {"expected":210,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":5} — the five recorded non-bundled authority IDs lack oracle implementations, so `scripts/test` accepts exactly this recorded state, exit 0; the oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `d6664f8a494a`, `NOISEMAKER_REQUIRE_ORACLE=1`) passes 230 runs, 1333 assertions, 0 failures, 7 skips, with the same accepted PARITY-SUMMARY line and exit 0. Run logs are archived with the job evidence under `range-audit-d6664f8/` (`suite-default.log` sha256 `04d7e2e8382b7ef378b7798328317261e1a4c24bd5e07620e7bd8f1e59fd36e5`, `suite-oracle.log` `4e8090b9949969721ed2416c5b3cb1f70b97ea91df64ae41c0fd51998cea62dd`, `digest-recompute.json` `2fdb9b071db319ad7e83db171f6fced1f3064b84d2c29f4da8cc5f70b7bb2ed4`, `audit.json` `af4ae87615dce668b4400ec612a6b56d8bf0bcec5101a01df580d7bbc6b4e2dd`, `commits.txt` `a67fdec38e404df70d4a8ef78d4f8e248d4c9e29c1a40fca1d3fd2601e40c7b7`, `log-numstat.txt` `9c817785cb2d08be5c240d65575802460ebd91946dd7fb2ae8ab4c2210e49532`, `shaders-diff.txt` `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty), all under a `SHA256SUMS` manifest). The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### Delivered-range audit, 2026-10-01 (sync to `116dae317a07`)

The delivered range `d6664f8a494aec3bd10bce200d63d42ec833d61a..116dae317a07a96d9f8ef3b0320f873871ff6b57` (2 commits; the job's flagged start `fd9d56c74ce7..116dae317a07` was audited: in a full clone of https://github.com/noisefactorllc/noisemaker-for-cpu.git `git merge-base --is-ancestor fd9d56c74ce7 116dae317a07` exits 0, and `fd9d56c74ce7` is itself an ancestor of the previous pin `d6664f8a494a`, so the flagged range is contiguous — machine-checkable audit: archived evidence `range-audit-116dae3/`, with `commits.txt`, `log-numstat.txt`, `audit.json`, `shaders-diff.txt` (empty) and a `SHA256SUMS` manifest). The two commits are the CPU repo's own GAP-003 records: `704645a45df9` records the CPU repo's 2026-10-01 M4/Metal authority-capture campaign for its 41 skip fixtures in the CPU repo's `docs/COMPLETION_GAPS.md` register, and `116dae317a07` corrects the CPU repo's own gate fixture `parity/upstream-defaults/synth3d__reactionDiffusion3d.dsl` (the fixture chained the starter effect after `noise3d`, which the authority compiler rejects) and updates the same register row. No `shaders/effects` or `shaders/src` file changes (`git diff d6664f8a494a 116dae317a07 -- shaders/effects shaders/src` is empty), the generated snapshot `src/effects/generated/upstream-snapshot.js` and `scripts/upstream/source-lock.js` are unchanged, and the CPU's upstream pin `e24c844f` and `PINNED_SOURCE_DIGEST` are unchanged — so the 205-effect catalog, parameter contracts, generated kernels, upstream source identity and the Ruby port's executable parity scope are all unchanged.

- Nothing to port from either commit: the corrected DSL fixture is consumed only by the CPU repo's own fixture tests (`test/parity-seed-fixtures.test.js`, `test/simulation-effects.test.js`), not by the oracle renderer (`bin/noisemaker-cpu.js` and `src/` do not read `parity/upstream-defaults/`), and this port's `scripts/parity.rb`/`scripts/parity-summary.rb` carry their own port-side fixtures and render the authority golden live through the pinned oracle rather than reading CPU-side fixture files. The `docs/COMPLETION_GAPS.md` edits update the CPU repo's own GAP-003 register, whose local counterpart is this port's independent GAP-001 record — no row text carries over.
- The pinned-source digest `c2e0c264dc20338b19a144ee0888bd2ca39edcf325315a7d7ae1f5ced920804d` was independently recomputed (not copied) by running the CPU checkout's `computePinnedSourceDigest` with node against a fresh clone of noisefactorllc/noisemaker checked out at `e24c844f`: the recomputed digest matches the CPU's recorded `PINNED_SOURCE_DIGEST` exactly (archived `range-audit-116dae3/digest-recompute.json`).
- Mirrored by repinning `scripts/oracle-lock.json` to CPU `116dae317a07` / upstream `e24c844f` / digest `c2e0c264…`, bound by `test/test_parity.rb#test_cpu_upstream_source_lock_and_snapshot_parity`, which ties the oracle's `source-lock.js`/`upstream-snapshot.js` pin strings to the lock at the same revision.

Binding evidence at the new pin: standalone suite 230 runs, 1250 assertions, 0 failures, 24 skips; whole-port `./scripts/parity-summary` (oracle provisioned at the lock revision `116dae317a07`) reports PARITY-SUMMARY {"expected":210,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":5} — the five recorded non-bundled authority IDs lack oracle implementations, so `scripts/test` accepts exactly this recorded state, exit 0; the oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean checkout of `116dae317a07`, `NOISEMAKER_REQUIRE_ORACLE=1`) passes 230 runs, 1333 assertions, 0 failures, 7 skips, with the same accepted PARITY-SUMMARY line and exit 0. Run logs are archived with the job evidence under `range-audit-116dae3/` (`suite-default.log` sha256 `f0cf4c1594737df96e260200e9e7a23536d03e4c6a748031f586f6bd668cd181`, `suite-oracle.log` `d0c373a2d4fd84d0598e18e01e68c03c7ce5ed176fa26b1973de80cba3a0bd46`, `digest-recompute.json` `5e90ede9bf151f5d004e892b7cf6fdb0f47bd5126759d8326c6f9753a83596d0`, `audit.json` `86e42530bc808eb666cc3bb3e2a3cdedd0f49fc1068208f029fc278745623b25`, `commits.txt` `c136609ccf6ccbe92f602983db8689a5d3ddd8c40ce297d47918184566e1ee4c`, `log-numstat.txt` `7619f04a0a36ee8e9a4dff0d606e765e9818e6cbe1e0ed1a9024bfc30812f2c1`, `shaders-diff.txt` `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty), all under a `SHA256SUMS` manifest). The supervisor's pre-review `scripts/test` run re-executes the gate at the exact candidate.

### GAP-001 qualification, 2026-09-29 (205 of 210 authority IDs)

The 13 effects that diverged at nondefault settings and the synth/testPattern colorBars runtime error were corrected (transpiler compound op-assign hoisting and destructure fixes, codegen vecN-argument and snap-condition fixes, oracle-faithful int/uint division semantics, filter/dither blockOrigin int-floor lowering, filter/median half-decode adapter fixes), and the committed bundle was fully regenerated to match the corrected transpiler and runtime at the pinned authority (commits `6591842c6a53a400cf574a8b92ae7408cbe5142a`, `2b161d0a76e2f21c41286f6b9d177c6146b64a84`, `e9c4f12fd2e3fa4b353edcd981702438bf9396da`). The whole-port machine check `./scripts/parity-summary`, owner-run at head `21002f8` with the retained transcript in the job evidence, reports PARITY-SUMMARY {"expected":205,"executed":205,"exact":205,"strict":0,"near":0,"defer":0,"skip":0,"fail":0,"missing":0} with exit 0. This is the 205-executable-ID result. The extended 1625-case grid at the corrected tree is byte-exact for every case; the raw merged and per-shard sweep reports are archived with the job evidence (`gap-001/parity-sweep-report-bfbe5476-full.json` and shards 0-5, SHA-256 digests recorded in that archive). Standalone suite: 230 runs, 0 failures with and without the pinned oracle. The count basis is the 205-ID bundle, not the 210-ID authority manifest. The five non-bundled IDs stay missing: the pinned oracle does not implement them, so no golden exists. GAP-001 stays open at the 210-ID basis. At the 2026-09-30 final-acceptance finding the whole-port entrypoint was fixed to count the full authority-manifest denominator: it now reports PARITY-SUMMARY expected 210, executed 205, exact 205, missing 5, exit 1 by design while the oracle lacks the five (see GAP-001's last verification); the 205/205 exit-0 lines above remain historical records of runs at the then-published 205-ID entrypoint.

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

Current served declaration: 205 effect IDs, equal to the bundle. This inventory is not evidence of execution. The declaration column below reflects kit `0.1.13` (the declaration set is unchanged from kit `0.1.9`).

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
| `classicNoisedeck/noise3d` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 112) |
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
| `filter/craquelure` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 1) |
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
| `filter/median` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 128) |
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
| `filter/spookyTicker` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 63-102) |
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
| `mixer/shapeMask` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 128) |
| `mixer/split` | yes | default + extended sweep exact |
| `mixer/thresholdMix` | yes | default + extended sweep exact |
| `mixer/uvRemap` | yes | default + extended sweep exact |
| `points/attractor` | yes | default + extended sweep exact |
| `points/buddhabrot` | yes | default + extended sweep exact |
| `points/dla` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 1) |
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
| `render/pointsBillboardRender` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 128) |
| `render/pointsEmit` | yes | default + extended sweep exact |
| `render/pointsRender` | yes | default + extended sweep exact |
| `render/render3d` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 142) |
| `render/renderCubemap3d` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 129) |
| `render/renderCubemapSurface` | yes | default + extended sweep exact |
| `render/renderLandscape3d` | yes | default + extended sweep exact |
| `render/renderLit3d` | yes | default + extended sweep exact |
| `synth/bitwise` | yes | default + extended sweep exact |
| `synth/cell` | yes | default + extended sweep exact |
| `synth/cellularAutomata` | yes | default + extended sweep exact |
| `synth/curl` | yes | default + extended sweep exact |
| `synth/gabor` | yes | default + extended sweep exact |
| `synth/gradient` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 1) |
| `synth/julia` | yes | default + extended sweep exact |
| `synth/mandala` | yes | default + extended sweep exact |
| `synth/mandelbrot` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 249) |
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
| `synth/testPattern` | yes | byte-exact (colorBars runtime error and size-16 divergence corrected 2026-09-29) |
| `synth3d/cell3d` | yes | default + extended sweep exact |
| `synth3d/cellularAutomata3d` | yes | default + extended sweep exact |
| `synth3d/flythrough3d` | yes | byte-exact (off-default corrected 2026-09-29; was maxdiff 13) |
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

GAP-001 is open at the 210-ID authority basis. The 13 diverging effects are corrected and the 205 executable IDs are byte-exact at the pinned authority. The five non-bundled authority-manifest IDs remain missing: the pinned oracle does not implement them, so no executable case exists.
Next bounded checks live in the [current status list](COMPLETION_GAPS.md#5-ordered-next-actions).
See [GAP-001 and the complete gap register](COMPLETION_GAPS.md#4-known-gaps) for evidence, dependencies, and acceptance criteria.

1. GAP-001 is open at the 210-ID basis. The five missing IDs need oracle-side implementation in `noisemaker-for-cpu` first, then porting and a whole-port re-run at 210. Keep the 205-ID evidence current whenever the runtime, transpiler, or pin changes.
2. GAP-003: closed for existing checkout/CDN distribution after the published-kit consumer upgrade. Repeat its lifecycle checks when distributed files change; RubyGems publication remains a separate owner decision. [Measured scope and evidence](COMPLETION_GAPS.md#gap-003-distribution-and-release-qualification).
3. Windows remains unqualified. Run its platform checks when an authorized Windows runner or host is available; this closure makes no Windows claim.
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
