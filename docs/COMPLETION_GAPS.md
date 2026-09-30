# noisemaker-for-ruby: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Scheduled audit: 2026-09-28. Current inspected source: [`b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8). Local `main` matched remote before checks. Checkout clean.
Full rendered parity is partial. GAP-001 is open. 205 of the 210 authority-manifest effect IDs are byte-exact at the pinned authority. The five non-bundled IDs have no executable case: neither the port bundle nor the pinned oracle implements them. GAP-002 closed for a measured matrix. No release approval follows from this audit.
Pinned authority: CPU `d2965d0b7880cee678de11ec797155c8a65c7b66`, upstream `f24b52540af6a88d12daa05feba1a04ad61b22a2` (lock repinned by this sync for the delivered range `fd9d56c74ce7..d2965d0b7880`; the previous pin `fd9d56c74ce7500b7eaeea90a93d3bf49375d28e` / upstream `73c15be00d6888f4b5d2835d8e242ee9e840df45` was set by the 2026-09-29 sync, earlier `bfbe54764eee` / `8eeb7b5a` by sync `a8f1ffe`; the sections below retain their measurements at the earlier pin `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c`). Post-repin qualification results are recorded in section 5 and bind their own pins.
Current CPU authority head: `d2965d0b7880cee678de11ec797155c8a65c7b66` — the pin; the delivered range was audited 2026-09-29 (see the compatibility report's "Delivered-range audit, 2026-09-29 (sync to `d2965d0b7880`)"). Pin updates belong to the sync job.
Upstream discovery: `f24b52540af6a88d12daa05feba1a04ad61b22a2`. CDN `/1.0/` manifest SHA-256 `05c4d7b7744837ae90a3bb4c89e5403ff09448a74d9d7e824abb3d719ad3314e` is unchanged. It still holds 210 effect IDs.
Current served kit: `0.1.13`, source `e9c4f12fd2e3fa4b353edcd981702438bf9396da` (updated 2026-09-29 after the GAP-001 parity fixes regenerated the packaged tree; the 2026-09-28 audit below verified the then-served `0.1.9` at source `91ae3f6` the same way). `0.1.13` is byte-verified in full: all 329 served files match the kit inventory hashes, 325 files are byte-identical to source `e9c4f12f` under the `kit.config.json` mappings, `compat.json` lists exactly the 205 bundled IDs, and `LICENSES/noisemaker-MIT.txt` is the vendored upstream notice.
`rubygems.org` returns 404 for this package. Distribution is build-from-checkout plus the export kit.

Daily review: 2026-09-25. Previously inspected source: [`d7942883e2e56486dd6c186486cd794cc3a512a4`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/d7942883e2e56486dd6c186486cd794cc3a512a4).

### Earlier source observations

Date: 2026-09-24. Reviewed SHA: [`379aa03df26df8b17f6916535c83328bb0e8eaa3`](https://github.com/noisefactorllc/noisemaker-for-ruby/commit/379aa03df26df8b17f6916535c83328bb0e8eaa3).
Local HEAD matched remote main before checks. The operator requested registers for all remaining eligible ports in this run.
This initial register contains bounded evidence. It is not a completed port audit or release approval.
No implementation or parity checkpoint changed. Full audits remain in the rotation.

Offline Ruby CPU renderer with 205 effects and 289 kernels. Ruby 3.2 is the documented floor. Large real-time rendering is outside its practical target. [Contract](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md).

`scripts/oracle-lock.json` pins CPU revision `16c38245c42030c8ee46dc61108791d2fea4bda9` and upstream revision `44bc4ed4ac729bddaa95b083d64bee942ade35da` in the sections below, which retain their historical measurements. That lock was repinned by sync commits `47a863d`, `0261bcf`, `0984199` to CPU `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` / upstream `2f47612c29045c1b91af94887a8ff20106e980ef` (source digest `182a4a518dcc52586d56470ae04ca17050babccd9fc53889fa2d2cc2ffbd7c5d`), and again by sync commit `a8f1ffe` (2026-09-28) to the current pin CPU `bfbe54764eee87c8f67d2b281d5f304faad04a5b` / upstream `8eeb7b5ac14eb37a8d16037f607a88ce63924cd3` (source digest `ceeccdd13b7b625b94c58dcfa318b4a253d5dc6d124e551233522fd5f32e399b`); see [evidence summary](evidence/gap-001/parity-evidence-summary.json) for the qualification structure and section 5 for the current-pin measurements. Historical pins, goldens, tolerances, and exclusions are preserved; no goldens were regenerated.
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
| CLAIM-004 | [README](https://github.com/noisefactorllc/noisemaker-for-ruby/blob/379aa03df26df8b17f6916535c83328bb0e8eaa3/README.md) | Release readiness | qualified for existing distribution | GAP-003 closed on 2026-09-29 after the published CDN consumer upgrade below. GAP-001 is open: parity covers 205 of the 210 authority IDs. RubyGems is unpublished and Windows unqualified; no new release is approved. |
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
| Distribution | Verified 2026-09-29: published kits 0.1.9 and 0.1.13 each pass 329/329 inventory checks; an isolated consumer renders before and after an in-place upgrade, recovers from invalid inputs, and is removed. Ruby 4.0.5, Darwin arm64; details in GAP-003. Earlier gem installation and removal evidence is retained. | GAP-003 closed for existing distribution. RubyGems remains unpublished; Windows remains unqualified. |
| Accessibility | CLI diagnostics checked. No graphical interface ships, so keyboard and focus checks do not apply. | Keep CLI diagnostics readable. |

Headless libraries do not require an editor accessibility test. Their CLI diagnostics and failure handling still require checks.
Host presence does not prove host qualification. This pass made no global installation or user-project changes.

## 4. Known gaps

P1 means false completion or major correctness failure. P2 means coverage or integration uncertainty. P3 means documentation inconsistency.
These entries record missing qualification. They do not infer implementation defects from absent tests.

### GAP-001: current authority and parity qualification

- Status: open (reopened 2026-09-29 by final acceptance). Priority: P2. Category: verification.
- Affected scope: noisemaker-for-ruby.gemspec, scripts/oracle-lock.json, scripts/parity.rb, scripts/parity-sweep.rb, scripts/parity-summary, test/, README.md
- Parity cases: whole port — every effect ID in the current authority manifest, 210 IDs. 205 IDs are executable: the port bundle and the pinned oracle inventory both hold 205 (`Renderer.meta`). The five non-bundled IDs (`render/meshLoader`, `render/meshRender`, `synth/roll`, `synth/scope`, `synth/spectrum`) have no executable case. The pinned oracle does not implement them, so no golden exists (see [COMPATIBILITY.md](COMPATIBILITY.md#3-parity-coverage)). `scripts/parity-summary` accepts explicit case ids and rejects ids outside the bundle as unknown.
- Expected behavior: Reproducible evidence binds each supported claim to the port and authority revisions.
- Observed behavior: Default gate is 205 of 205 effects byte-exact at the pinned authority on Ruby 3.2.8 and 3.4.5. The extended sweep covered 1625 cases: nondefault parameters, animation, iterated state, seed 7, 16x16, and volumeSize 8, at byte-exact tolerance. It initially found 17 differing cases across 13 effects and one Ruby runtime error (synth/testPattern pattern=colorBars). After the corrections landed (post-`3059d59` commits `6591842c`, `2b161d0a`, and the bundle rebuilds `2b161d0a` batch 1 and `e9c4f12f` batch 2 — see the 2026-09-28 history rows and "GAP-001 requalification at the repinned authority" below), the whole-port gate reports PARITY-SUMMARY expected 205, executed 205, exact 205, strict 0, near 0, defer 0, skip 0, fail 0, missing 0, exit 0. This is the owner-run 205-executable-ID result. The retained transcript binds it to head `21002f8` and the pinned oracle. The extended 1625-case grid at the corrected tree is byte-exact for every case (raw merged and per-shard reports archived with the job evidence, `gap-001/parity-sweep-report-bfbe5476-*.json`). The five non-bundled authority IDs remain unexecuted. The pinned oracle does not implement them, so no golden exists for them. Count basis against the 210-ID authority: executed 205, missing 5.
- Evidence: machine check `./scripts/parity-summary` (POSIX launcher; exit 0; owner-run, with the transcript retained). A source-bound raw transcript of a fresh whole-port run at head `21002f8` is retained with the 2026-09-29 job evidence. See Worker Elves job `57032d28-42c9-4794-b016-599fe6176be0`, evidence `evidence-1790722920442.tar.gz`, path `review-20260929-215800/gap-001-head-21002f8/parity-summary.log` and its `manifest.json`. The transcript records the command, exit code 0, and the final PARITY-SUMMARY line. It binds port commit `21002f8` (tree `983ea72d`) and pinned oracle `d2965d0b`. PARITY-SUMMARY reported 205 expected, 205 executed, 205 exact, and zero in every other count. The summary's executed/defer accounting was corrected at the published implementation commit `ac5919c8f251eb9594b2aae3f235d066292440ab`; re-running the published entrypoint there reports the same counts (run log `gap-003/parity-summary.log`, archived with the job evidence). Archived raw sweep reports `gap-001/parity-sweep-report-bfbe5476-full.json` + shards 0-5 (SHA-256-bound in the job evidence); committed [earlier-pin sweep report](evidence/gap-001/parity-sweep-report.json), [evidence summary with source hashes](evidence/gap-001/parity-evidence-summary.json), [raw Ruby 3.2.8 default-gate log](evidence/gap-001/parity-default-ruby-3.2.8.log), [compatibility matrix](COMPATIBILITY.md#3-parity-coverage), and section 3.
- Next action: the five missing authority IDs need oracle-side implementation in noisemaker-for-cpu first; without an oracle golden, no parity case can exist. After the oracle implements them, port the five effects, then re-run the whole-port summary at 210. Until then, keep the 205-ID evidence current at each authority or source change.
- Dependencies: Immutable authority inputs are resolved and recorded (current lock pins CPU `d2965d0b7880cee678de11ec797155c8a65c7b66` / upstream `f24b52540af6a88d12daa05feba1a04ad61b22a2` after the `fd9d56c74ce7` and `d2965d0b7880` repins; earlier pins `bfbe54764eee`/`8eeb7b5a` via `a8f1ffe` and `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1`/`2f47612c` via `47a863d`, `0261bcf`, `0984199`, and historical pins, goldens, and tolerances preserved). Release claims additionally need GAP-003. The five non-bundled authority IDs need oracle-side implementation in `noisemaker-for-cpu`; without it, no parity case or golden can exist for them.
- Acceptance criteria: Report every applicable case, parameter choice, exclusion, error, and tolerance. Do not reduce the denominator to report success. Not met at the 210-ID whole-port basis: five cases missing. The 205 executable IDs pass: PARITY-SUMMARY all zeros except expected/executed/exact = 205, and the extended grid 1625/1625 byte-exact at the corrected tree.
- Required checks: Existing compiler and rendered parity gates, with raw output and exact source hashes.
- Last verification: 2026-09-30. Fresh `./scripts/parity-summary` at the published head `053cbef2cd1001aea5b8a17948c539c9d9745dc2` (tree `45638111069e7e043c6897650d4bbdd2d6fccf65`): exit 0, PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0, with the oracle provisioned at the lock revision `d2965d0b7880cee678de11ec797155c8a65c7b66` (provisioned checkout HEAD verified equal); raw log and provenance manifest archived with Worker Elves job `6ae63481-449f-4744-8385-18faf173e4cd` (`gap-001-head-053cbef-parity-summary.log`, `gap-001-head-053cbef-manifest.json`). Oracle recheck: noisemaker-for-cpu head `ce3926d` contains only docs commits since the pin (no `src`/`shaders` change), and the five non-bundled IDs still have no effect records in the CPU oracle — only `sourceEffectIds` manifest entries — so no golden can exist for them. The blocker stands; the 205-ID evidence is current. The prior owner-run transcript at head `21002f8` remains cited above.

### GAP-001 qualification runs, 2026-09-26

The locked 205-effect comparator ran at the pinned authority `aaa6df50421d9d6db752289cdc1ff7c1efb1d9d1` (upstream `2f47612c29045c1b91af94887a8ff20106e980ef`, verified clean checkout) against Ruby 3.2.8 and Ruby 3.4.5. All runs were executed on a clean tree at pre-publication HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc` (each run's header records that HEAD with `git_dirty: false`); the published candidate adds only the committed evidence files, which sit outside the harness source-hash globs, so `candidate.source_hashes` in the committed report are identical at that HEAD and at this commit (verified after the final amend). The default gate (size 8, seed 1, time 0.25, one scene per effect) is 205 of 205 effects byte-exact on Ruby 3.2.8 (gate transcript: [parity-default-ruby-3.2.8.log](evidence/gap-001/parity-default-ruby-3.2.8.log) — annotated provenance header lines 1-5 added by the invocation wrapper, followed by parity.rb's raw output and exit status). The extended sweep ([raw report](evidence/gap-001/parity-sweep-report.json), [summary with source hashes](evidence/gap-001/parity-evidence-summary.json)) executed 1625 RGBA8 cases across all 205 effects — default scene, up to 3 nondefault-parameter cases per effect (560 executed, 922 parameters excluded with reasons in the report: 826 capped, 41 without a derivable nondefault value, 55 bound via inputs), animation times 0.0 and 1.0, iterated state at iterationCount 3, seed 7, 16x16 scenes, and volumeSize 8 for volume effects — with byte-exact RGBA8 tolerance and no skipped or tolerated differences. 1607 cases are byte-exact; 17 cases across 13 effects differ (maxdiff 1-255) and one Ruby runtime error was observed (synth/testPattern with pattern=colorBars: "can't convert Array into Float"). These are port defects at nondefault settings, listed per effect in the [compatibility matrix](COMPATIBILITY.md#3-parity-coverage) and the evidence summary. The extended sweep ran on Ruby 3.4.5; the committed report is the output of the committed `scripts/parity-sweep.rb` in `--merge` mode (its header records the full merge invocation; the per-run `command` fields in the shard reports record the bare invocation because an option-parsing bug dropped arguments before the field was written, fixed in the committed harness; each run records its ruby version, HEAD `7f3d4261b9533aa2f85a228463a73f06a42be7cc`, and `git_dirty: false`; the committed harness hash is in the summary). Exact-source CI for these documents is the publication gate; run ids are cited in the evidence summary and section 2. Full behavior qualification remains open until the 13 diverging effects are corrected and re-swept.

### GAP-001 requalification at the repinned authority, 2026-09-28 (sync `a8f1ffe`)

Sync `a8f1ffe` repinned `scripts/oracle-lock.json` to the delivered noisemaker-for-cpu range end `bfbe54764eee87c8f67d2b281d5f304faad04a5b` (upstream `8eeb7b5ac14eb37a8d16037f607a88ce63924cd3`, source digest `ceeccdd13b7b625b94c58dcfa318b4a253d5dc6d124e551233522fd5f32e399b`) and ported the range's renderer viewport/texture-dimension semantics. Both gates were re-executed fresh at commit `a8f1ffe` on a clean tree against a clean checkout of the pinned revision (Ruby 3.4.5, Node 26.5.1, Linux x86_64): the default gate (size 8, seed 1, time 0.25) is 205 of 205 effects byte-exact, exit 0; the full extended sweep (all 205 effects, `scripts/parity-sweep.rb` shards 0..5) executed 1625 RGBA8 cases — 1607 byte-exact, 17 cases across 13 effects differing (maxdiff 1-255) and the same single Ruby runtime error (synth/testPattern pattern=colorBars: "can't convert Array into Float"). The 18 non-exact cases were compared programmatically, case-by-case, against the committed report at the earlier pin: the (effect, case, status) sets are identical — the repin and the renderer change introduced no new divergence, and the pre-existing diff set is unchanged in membership and maxdiff. Per this repository's publication policy the raw gate log and sweep reports of these runs are retained in the supervisor's archived job evidence (Worker Elves job `6e194787-c477-4318-8bbf-84fdc83fa4d6`, files `parity-default-gate-a8f1ffe-code.log` and `sweep-a8f1ffe/` incl. `TOTAL.txt`: cases=1625 exact=1607 nonexact=18) rather than regenerated under `docs/evidence/`, which continues to hold the earlier-pin evidence set unchanged.

Provenance and machine-checkability of these numbers: the default-gate result at the new pin is machine-checked in-repo by [export-kit.yml](../.github/workflows/export-kit.yml)'s parity job, which runs `scripts/parity.rb` against the oracle checked out at the `scripts/oracle-lock.json` revision on every push to `main` (Actions run 36393070099 at `a8f1ffe`, whose code is identical to this record's scope, passed). The extended-sweep counts above were executed by the sync job itself (Worker Elves job `6e194787-c477-4318-8bbf-84fdc83fa4d6`) against a clean checkout of the pinned revision; the repository's publication policy keeps raw sweep output out of `docs/evidence/`, and this job holds no workflow-change authority to add an in-repo automated sweep check, so these counts are backed by the supervisor's retained run artifacts (files `parity-default-gate-a8f1ffe-code.log` and `sweep-a8f1ffe/`, incl. `TOTAL.txt`: cases=1625 exact=1607 nonexact=18) rather than by a committed evidence file. They are independently reproducible with the committed harness at the pin: `NOISEMAKER_CPU_DIR=<clean checkout of the scripts/oracle-lock.json revision> ruby scripts/parity-sweep.rb --shard <0..5>/6 --report <path>` and `--merge`. Full behavior qualification remains open until the 13 diverging effects are corrected and re-swept at the then-current pin.

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

- Status: closed for existing distribution and the qualified matrix (2026-09-29). Priority: P2. Category: release. The earlier same-day closure was premature and final acceptance reopened it; the published-kit consumer qualification below supplies the missing evidence.
- Affected scope: Actual artifact, dependencies, notices, version promises, and release evidence.
- Expected behavior: The delivered artifact supports its documented installation and first useful result.
- Observed behavior: Audit 2026-09-28 byte-verified the served kit `0.1.9` in full (329/329 inventory hashes, 327 byte-identical to source `91ae3f6`). After the GAP-001 parity fixes regenerated the packaged tree, the served kit moved to `0.1.13` at source `e9c4f12f` and this job byte-verified it fresh on 2026-09-29: all 329 served files match the `kit.json` hashes, 325 files are byte-identical to `e9c4f12f` under the `kit.config.json` mappings, `compat.json` equals the 205 bundled IDs, and `LICENSES/noisemaker-MIT.txt` is the vendored upstream notice; `lib`, `exe`, and `LICENSE` are unchanged from `e9c4f12f` to the current candidate, so the kit's engine bytes equal the current candidate. The upstream notice matches `noisemaker@2f47612c`. Gem build, isolated install, metadata, and removal pass (section 3). Preparatory upgrade probes (2026-09-29), not the published-version upgrade this gap requires: gem `0.0.0` built from a clean archive of this checkout installs and renders in an isolated `GEM_HOME`; a copy of the same checkout with `lib/noisemaker_cpu/version.rb` bumped to `0.0.1` builds and `gem install` upgrades it (both versions installed, newest default); first render on the upgraded version produces a valid PNG; `gem uninstall` removes the gem and its executable (the first render invocation failed with `noisemaker-rb: command not found` until `GEM_HOME/bin` was added to `PATH`; the archived transcript records both attempts). Kit upgrade: kits `0.1.9` (source `91ae3f6`) and `0.1.13` (source `e9c4f12f`) both serve at versioned CDN paths and each matches its full `kit.json` inventory (329/329 hashes each); a staged `0.1.9` tree upgraded to `0.1.13` (290 files change, file set unchanged) byte-matches the `0.1.13` inventory for all 329 files afterwards. These earlier probes covered upgrade mechanics only. The final acceptance decision kept the gap blocked pending a real consumer upgrade; the subsequent qualification below uses two published CDN versions. RubyGems still has no published version. Maintained versions for new installations are identified: [Ruby maintenance branches](https://www.ruby-lang.org/en/downloads/branches/) list 3.4 and 4.0 under normal maintenance, and README Install directs new installations to 3.4 or 4.0 while keeping the 3.2 floor. Distribution remains build-from-checkout plus the export kit.
- Parity cases: none — this is a distribution gap, not a rendered-parity gate. Rendered parity is GAP-001's scope: 210 authority-manifest IDs, 205 verified byte-exact, five missing because the pinned oracle does not implement them. The kit's compat declaration equals the 205 bundled IDs.
- Evidence: Section 3, [kit metadata](https://kits.noisedeck.app/ruby/0/deployment-meta.json), exact-source CI in section 2, and [README Install](../README.md). The `scripts/parity-summary` executed/defer accounting fix is published at `ac5919c8f251eb9594b2aae3f235d066292440ab` (export-kit CI run 36532913056 success; `./scripts/parity-summary` at that commit: exit 0, PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0 — run log `gap-003/parity-summary.log`, archived with the job evidence; the supervisor's pre-review `scripts/test` run of each new candidate re-executes the entrypoint and its PARITY-SUMMARY line at that candidate). Kit evidence: `0.1.13` byte verification (`gap-003/kit-0.1.13/verify.json`) and the `0.1.9` → `0.1.13` upgrade probe (`gap-003/kit-upgrade/upgrade-probe.json`, `upgrade-result.json`, staged trees `v9/`, `v13/`, `upgraded/`). Gem-upgrade probe evidence: `gap-003/upgrade/` (`run.log`, `gem-upgrade-transcript-part1.log`, both `.gem` files, `a-solid.png`, `b-curl.png`). All archived with the job evidence.
- Next action: Requalify installation, upgrade, recovery, and removal when the distributed runtime changes. Recheck maintained-version guidance at each audit. RubyGems publication remains a separate owner decision. Windows remains unqualified; its checks need an authorized Windows runner or host.
- Dependencies: (1) GAP-001 full parity — open: 205 of 210 authority IDs verified, five missing because the oracle does not implement them. Distribution qualification does not depend on those five. (2) A published artifact or an explicit build-from-checkout release decision — met by the existing versioned CDN artifacts `0.1.9` and `0.1.13`; no RubyGems publication or new release decision is claimed.
- Acceptance criteria: Match artifact bytes to their inventory; check notices and dependencies; pass installation, examples, upgrade, and removal. Met for existing distribution: earlier isolated gem checks remain in section 3; the published-kit consumer checks below verify both inventories, notices, zero-install execution, upgrade, recovery, and cleanup on Ruby 4.0.5 Darwin arm64. The synthetic gem version bump remains preparatory evidence only.
- Required checks: Inspect exact-source CI jobs and render legs; count skips and errors rather than trusting green summaries. [CI run 36532913056](https://github.com/noisefactorllc/noisemaker-for-ruby/actions/runs/36532913056) at `ac5919c` reports 230 integration tests, 1,432 assertions, zero failures/errors, six skips; all five standalone legs report 230 tests, 1,342 assertions, zero failures/errors, 24 skips. Rendered parity is 205/205 byte-exact, zero differences/runtime/oracle errors. The [comparison to inspected source `6f7a2c7`](https://github.com/noisefactorllc/noisemaker-for-ruby/compare/ac5919c8f251eb9594b2aae3f235d066292440ab...6f7a2c7eb23e9bd9fddae5f1573946d37346e983) changes only these two qualification documents. The published `scripts/parity-summary` count must remain all-zero at its 205-ID scope.
- Last verification: 2026-09-29. Existing checkout/CDN distribution qualified within the measured matrix. RubyGems remains unpublished and Windows unqualified. This register does not approve a new release.

Published-kit consumer qualification, 2026-09-29: Ruby 4.0.5, Darwin 25.5.0 arm64. Downloaded every file listed by the immutable [0.1.9 inventory](https://kits.noisedeck.app/ruby/0.1.9/kit.json) and [0.1.13 inventory](https://kits.noisedeck.app/ruby/0.1.13/kit.json), checking each byte count and SHA-256: 329/329 pass for each version, including both MIT notices. Their source identities are `91ae3f6008001678d311dbc06f1f485c577d71ce` and `e9c4f12fd2e3fa4b353edcd981702438bf9396da`; the [comparison from the latter to `6f7a2c7`](https://github.com/noisefactorllc/noisemaker-for-ruby/compare/e9c4f12fd2e3fa4b353edcd981702438bf9396da...6f7a2c7eb23e9bd9fddae5f1573946d37346e983) changes no shipped kit files. Copied `0.1.9` into an isolated consumer directory, added the program below, then replaced its shipped files with `0.1.13`. All 329 installed files matched the new inventory; the consumer program and previous output remained unchanged. No global gem or dependency installation was required.

```ruby
search synth, filter
noise(seed: 3, ridges: true).vignette().write(o0)
render(o0)
```

Commands through the shipped entry points (all renders at 16×16):

```sh
ruby run.rb program.dsl --width 16 --height 16 --seed 3 --time 0.25 --output before.png
# Replace the shipped files with verified 0.1.13 files, preserving consumer data.
ruby run.rb program.dsl --width 16 --height 16 --seed 3 --time 0.25 --output after.png
ruby engine/exe/noisemaker-rb generate synth/solid --width 16 --height 16 --param 'color=#4080c0' --filename after-solid.png
ruby engine/exe/noisemaker-rb generate synth/nope --width 16 --height 16 --filename after-solid.png
ruby engine/exe/noisemaker-rb generate synth/solid --width 16 --height 16 --param color=zzz --filename after-solid.png
ruby engine/exe/noisemaker-rb generate synth/curl --width 16 --height 16 --seed 1 --param scale=16 --filename recovered.png
ruby engine/exe/noisemaker-rb apply filter/lighting recovered.png --filename filtered.png
```

Both program renders exited 0 and decoded to identical RGBA pixels with 256 distinct colors (RGBA SHA-256 `29ee8efa0c03dd7b72e18697e801a10c35af42a5fb3a5d5117cb635a608a397f`). Solid was also rendered before replacement; both versions produced `(64,128,192,255)` at every pixel. Invalid effect and invalid color exited 2 with specific diagnostics and left `after-solid.png` unchanged. Corrected curl and lighting renders exited 0, yielding 256 and 252 distinct colors respectively. All PNG chunk CRCs and decoded dimensions passed. Removed the consumer and both downloaded kit trees and asserted their absence; global installation was untouched. Compact command/result/hash evidence is retained by the operator (`verification.json`, SHA-256 `bbcf2f7f94fb63c6cb2e6e573e3a04ccdb08dc990e6a92e4f62da563502c71d8`). This measures the existing CDN upgrade on the stated host, not a RubyGems upgrade or Windows support.

## 5. Ordered next actions

Current first action: GAP-001 — the five missing authority IDs need oracle-side implementation in noisemaker-for-cpu, then porting and a whole-port re-run at 210. GAP-003 closed for existing distribution after the published-kit consumer upgrade; RubyGems remains unpublished and Windows unqualified.
Subsequent actions depend on that evidence. No implementation is authorized by this audit.

1. GAP-001 is open at the 210-ID authority basis. The 13 diverging effects are corrected and the 205 executable IDs are byte-exact. The five missing IDs need oracle-side implementation in `noisemaker-for-cpu` first, then porting and a whole-port re-run at 210.
2. GAP-003: closed for existing checkout/CDN distribution. Repeat the published-kit consumer lifecycle checks when distributed files change; RubyGems publication remains a separate owner decision.
3. Windows remains unqualified. Run its platform checks when an authorized Windows runner or host is available; this closure makes no Windows claim.
4. Keep GAP-002 evidence current whenever entry points change. Re-run the installed workflow probes after any CLI or library change.
5. Keep GAP-001 evidence current at each authority or source change. Pin updates belong to the sync job.

Implementation belongs to the separate job. Do not port additional effects or advance the current parity checkpoint through this register.

## 6. Pass history

2026-09-25 daily review at `d7942883e2e56486dd6c186486cd794cc3a512a4`: source freshness and bounded evidence reviewed. Open qualification limits retained. Retained review evidence: Actions run 36076250675 (retained by the operator review — exact-source Actions are linked above). No new closure claimed.

2026-09-28 scheduled audit at `b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8`: default parity gate re-executed 205/205 byte-exact at the pinned oracle. The focused sweep re-ran the 13 diverging effects and reproduced the committed non-exact cases. GAP-002 closed for the qualified matrix. Served kit `0.1.9` byte-verified in full. Five false inventory rows corrected in COMPATIBILITY.md. No release approval.

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-29 | this sync commit | Sync of noisemaker-for-cpu `fd9d56c74ce7..d2965d0b7880` (force-push flag audited: `git merge-base --is-ancestor fd9d56c74ce7 d2965d0b7880` exits 0, so the range is contiguous — 10 commits, 9 docs-only; machine-checkable audit archived as `range-audit-d2965d0/`): oracle lock repinned to `d2965d0b7880`/upstream `f24b5254`/source digest `f11af18a…`, independently recomputed against a fresh upstream clone at `f24b5254`. The range changes no `shaders/effects` or `shaders/src` file (upstream delta is GAP-032 audio-input runtime work the headless port does not consume), and the CPU snapshot changed only in its revision field, so the committed bundle and the 205-ID parity scope are unchanged (see the compatibility report's "Delivered-range audit, 2026-09-29 (sync to `d2965d0b7880`)"). | Standalone suite 230 runs, 0 failures, 24 skips; whole-port `./scripts/parity-summary` at the new pin: PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0, exit 0 (oracle at the lock revision `d2965d0b7880`); oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean `d2965d0b7880` checkout) 230 runs, 0 failures, 7 skips, including `test_cpu_upstream_source_lock_and_snapshot_parity` binding the lock to the pin. | 205 of 210 authority IDs byte-exact at the pin; five missing, GAP-001 open. GAP-003 is closed for existing checkout/CDN distribution as of this date (RubyGems publication remains a separate owner decision; Windows remains unqualified). |
| 2026-09-29 | this sync commit | Sync of noisemaker-for-cpu `bfbe54764eee..fd9d56c74ce7` (nine forced, non-contiguous delivery ranges audited as their union: 37 commits, 32 files): oracle lock repinned to `fd9d56c74ce7`/upstream `73c15be0`/source digest `b78f27e2…`; the range changes no `shaders/effects` file (upstream delta is editor/preflight/diagnostics instrumentation only), so the committed bundle and the 205-ID parity scope are unchanged; browser-demo a11y controls, CPU-side golden-provenance reporting and CPU-side tests are recorded as intentionally not carried (see the compatibility report's "Delivered-range audit, 2026-09-29 (sync to `fd9d56c74ce7`)"). | Standalone suite 230 runs, 0 failures, 24 skips; whole-port `./scripts/parity-summary` at the new pin: PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0, exit 0 (oracle provisioned at the lock revision); oracle-present suite (`NOISEMAKER_CPU_DIR` at a clean `fd9d56c74ce7` checkout) 230 runs, 0 failures, including `test_cpu_upstream_source_lock_and_snapshot_parity` binding the lock to the pin. | 205 of 210 authority IDs byte-exact at the pin; five missing, GAP-001 open. RubyGems publication and Windows remain open (GAP-003). |
| 2026-09-28 | `a8f1ffe131167f201cda03b39f930bb2a2f8a010` | Sync of noisemaker-for-cpu `36fbfac07be5..bfbe54764eee`: renderer viewport/texture-dimension semantics, oracle lock repinned to `bfbe54764eee`/upstream `8eeb7b5a`, executable `scripts/test` entrypoint added. GAP-001 stays open (same 13 diverging effects); GAP-001 evidence requalified at the new pin. | Default gate 205/205 byte-exact and full extended sweep 1625 cases (1607 exact, 17 diff + 1 error) at the new pin, with the non-exact (effect, case, status) set programmatically identical to the committed earlier-pin report. Standalone suite 230 runs, 0 failures. Export-kit CI run 36393070099 success. Raw gate/sweep outputs retained in the supervisor's archived job evidence, cited in section 5. | 13 effects diverge at nondefault settings; full parity, upgrade, rubygems publication, and Windows remain open. |
| 2026-09-29 | this closure commit | Delivered-range audit recorded: the six forced, non-contiguous CPU ranges audited as their union `36fbfac07be5..bfbe54764eee` (17 commits, 21 files) in a fresh clone; every rendered-output change mapped to the port (see docs/COMPATIBILITY.md "Delivered-range audit, 2026-09-29"). The browser-canvas `CanvasSink` API is recorded as intentionally not carried (no DOM canvas in the headless port; no rendered-output behavior). | Mapping is bound by the whole-port PARITY-SUMMARY 205/205 byte-exact at this exact commit (archived run log with commit and tree hashes, `range-audit/parity-summary-d43a61e0dcea023c8e5a8b95d72e3cba2656fb08.log`) and the byte-exact extended grid at the pin; the upstream-range raw audit artifacts (per-commit log, per-file blob digests, sink/renderer diffs) are archived with sha256 bindings cited in docs/COMPATIBILITY.md; oracle lock/snapshot pin strings tied to the port lock by `test_cpu_upstream_source_lock_and_snapshot_parity`. | 205 of 210 authority IDs byte-exact; five missing, GAP-001 open. RubyGems publication and Windows remain open (GAP-003). |
| 2026-09-29 | `e9c4f12fd2e3fa4b353edcd981702438bf9396da` (bundle complete) and this closure commit | GAP-001 recorded closed at the time (reopened 2026-09-29 by final acceptance at the 210-ID basis): all 13 diverging effects and the colorBars runtime error corrected across `6591842c`/`2b161d0a`/`e9c4f12f`; bundle fully regenerated. | Whole-port `scripts/parity-summary` at the then-published candidate, owner-run (job-archived run logs): PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0, exit 0. Extended 1625-case grid byte-exact at the corrected tree (raw reports archived with the job evidence, `gap-001/parity-sweep-report-bfbe5476-*.json`). Standalone suite 230 runs, 0 failures with and without the pinned oracle; export-kit CI runs 36491438334, 36497887168, 36502723344 success. | 205 of 210 authority IDs byte-exact at the pin; five missing, GAP-001 open. RubyGems publication and Windows remain open (GAP-003). |
| 2026-09-29 | this closure commit | GAP-003 record: served kit `0.1.13` (source `e9c4f12f`) byte-verified fresh (329/329 hashes, 325 byte-identical to source, compat equals the 205 bundled IDs); preparatory upgrade probes recorded (synthetic same-checkout gem bump `0.0.0`→`0.0.1` in an isolated `GEM_HOME`; staged kit upgrade `0.1.9`→`0.1.13` byte-verified post-upgrade, 329/329); `scripts/parity-summary` executed/defer accounting fixed at the published implementation commit `ac5919c` (PARITY-SUMMARY 205/205 exact, exit 0, CI run 36532913056). The gap closed the same day and was reopened at final acceptance: it is blocked. | Export-kit CI 36532913056 at `ac5919c` success; evidence archived with the job (`gap-003/parity-summary.log`, `gap-003/kit-0.1.13/`, `gap-003/kit-upgrade/`, `gap-003/upgrade/`). Distribution remains build-from-checkout plus the export kit; no published version exists. | Blocked: no published artifact or owner release decision; upgrade of a published version untested; Windows unmeasured. The five non-bundled authority-manifest IDs stay outside the published parity count (no executable case). |
| 2026-09-28 | `6591842c6a53a400cf574a8b92ae7408cbe5142a` and its bundle-rebuild successor | Post-`3059d59` parity corrections: runtime/codegen/lowering fixes (compound op-assign hoisting, each_with_index destructure fix, vecN-arg wrap, JS int/uint semantics, unsigned hash helper, median NaN-gated half decode, dither blockOrigin int-floor), `scripts/parity-summary` entrypoint, regenerated test goldens, and regenerated bundle kernels (batched by review size limits). GAP-001 remains open pending the records-only closure commit. | Whole-port `scripts/parity-summary` at the published correction commit and at the bundle-rebuild commit: PARITY-SUMMARY expected 205, executed 205, exact 205, strict/near/defer/skip/fail/missing 0, exit 0; archived in the job evidence (step2a/). Standalone suite 230 runs, 0 failures with and without the pinned oracle. Export-kit CI run 36491438334 success at `6591842`. | GAP-001 closure (records-only commit citing the supervisor's candidate-bound parity-summary run) and rubygems/Windows (GAP-003) remain open. |
| 2026-09-28 | `b02f816a43a8e467e7c2adff3b1cc4fe4289e0f8` | This audit: fresh default-gate execution, focused divergent sweep, installed-workflow probes, served-kit byte verification, carried-evidence hash check, five false inventory rows corrected. GAP-002 closed for the qualified matrix. | Default gate 205/205 byte-exact (Ruby 3.4.5, pinned oracle). Focused sweep 107 cases: 89 exact, 17 diff, 1 error, matching the committed report. Standalone suite 229 runs, 24 skips. Kit 329/329 hashes. Gem install, probes, and removal pass. Cancellation and file preservation pass. | 13 effects diverge off-default. Full parity, upgrade, rubygems publication, and Windows remain open. |
| 2026-09-26 | this commit | Extended GAP-001 qualification: comparator run at the pinned authority, extended sweep evidence committed, authority repin documented, operator-local evidence links removed. GAP-001 remains open (13 diverging effects). | Default gate 205/205 byte-exact (Ruby 3.2.8 and 3.4.5); extended sweep 1607/1625 cases exact with every case, exclusion, error, and tolerance recorded. | 13 effects differ at nondefault settings; installed workflow, platforms, and releases remain unqualified. |
| 2026-09-24 | `379aa03df26df8b17f6916535c83328bb0e8eaa3` | Created six-section register and README link. No closures. | Five public API tests passed with 68 assertions. Full parity, package installation, and minimum-version checks were not rerun locally. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `audit-20260928-035500`. This run's raw evidence: shared series store at `/series/evidence-audit-20260928-035500/`.
Earlier runs: `20260924-remaining-gap-documents`, the 2026-09-25 daily review, and the 2026-09-26 extended qualification.
Operational evidence (operator-retained, not committed to this repository). Creating this register does not advance successful-audit timestamps or the rotation.
