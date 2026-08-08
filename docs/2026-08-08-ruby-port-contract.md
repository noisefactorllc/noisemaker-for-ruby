# noisemaker-for-ruby — Port Contract

**Date:** 2026-08-08 · **Status:** Binding for all port workers

Conventions for the Ruby port of the `noisemaker-cpu` engine. Follow exactly;
when something here conflicts with what you find in the references, flag it in
your report instead of improvising.

## Mission

Pure-Ruby port of the noisemaker-cpu shader engine, same shape as the sibling
python and perl ports: GLSL→Ruby transpiler, float32-faithful runtime, the
167-effect bundle (211 kernel files), Polymorphic DSL, PNG I/O, CLI, and the
cross-language parity harness.

**Definition of done for the repo:** `scripts/parity.rb` reports **167/167
pass (≤2 bytes/channel)** against the JS oracle at 8×8, seed 1, time 0.25 —
matching today's measured perl baseline (164 byte-exact; known ≤2 near-misses:
`filter/mosaicTiles`, `filter/stipple`, `filter/strokes`).

## References (all READ-ONLY)

| Role | Repo (checked out as a sibling directory during the build) |
|---|---|
| **PRIMARY template — translate from this** | [noisemaker-for-perl](https://github.com/noisefactorllc/noisemaker-for-perl) |
| Secondary cross-check (python port) | [noisemaker-for-python](https://github.com/noisefactorllc/noisemaker-for-python) |
| JS oracle / reference engine | [noisemaker-for-cpu](https://github.com/noisefactorllc/noisemaker-for-cpu) |
| Shared design doc | `noisemaker-for-python/docs/2026-07-15-noisemaker-python-perl-design.md` |

(During the build session the perl repo was read from a temporary local
clone; path literals elsewhere in this doc reflect that session. The durable
convention is sibling checkouts, as `scripts/parity.rb` assumes for the JS
oracle.)

Never create, modify, or delete anything outside the `noisemaker-for-ruby` checkout.

## Identity & toolchain

- Gem **`noisemaker-for-ruby`** v0.0.0 · require path **`noisemaker_cpu`** ·
  module **`NoisemakerCpu`** · CLI **`exe/noisemaker-rb`** · MIT © 2026 Noise Factor LLC.
- Interpreter: **`/opt/homebrew/opt/ruby/bin/ruby`** (4.0.5). Never bare `ruby`
  (system Ruby is 2.6). Gemspec floor: `>= 3.2`.
- **Zero runtime gem dependencies.** Stdlib only: `zlib`, `json`, `stringio`,
  `optparse`; `net/http` in the transpiler CDN module only. Tests: `minitest`.
- Hand-written lib files start with `# frozen_string_literal: true`.
  Generated kernel files do not.

## Translation doctrine

1. **Perl is the source. Translate 1:1** — file-for-file, sub-for-method,
   preserving names (already snake_case), control flow, magic constants, and
   explanatory comments. Python is the cross-check where perl is unclear; the
   JS engine source decides disputes (flag any such dispute in your report).
2. **No innovation.** Do not optimize, simplify, "rubyfy", or reorder float
   arithmetic. Keep GPU-workaround idioms (hard-capped `for` + `break`)
   verbatim. Evaluation ORDER of float ops is part of the spec.
3. **Never weaken a test or golden value.** Port assertions exactly.

## File map (perl → ruby)

| Perl (`lib/Math/Fractal/Noisemaker/`) | Ruby (`lib/noisemaker_cpu/`) | Worker |
|---|---|---|
| `UintMath.pm` | `uint_math.rb` | A |
| `Runtime.pm` | `runtime.rb` | A |
| `Surface.pm` | `surface.rb` | A |
| `TextureFormat.pm` | `texture_format.rb` | A |
| `Sampler.pm` | `sampler.rb` | A |
| `PaletteData.pm` | `palette_data.rb` | A |
| `Transpiler/SharedEnums.pm` | `transpiler/shared_enums.rb` | B |
| `Transpiler/ComputedDefs.pm` | `transpiler/computed_defs.rb` | B |
| `Transpiler/Lexer.pm` | `transpiler/lexer.rb` | B |
| `Transpiler/Preprocess.pm` | `transpiler/preprocess.rb` | B |
| `Transpiler/Parser.pm` | `transpiler/parser.rb` | B |
| `Transpiler/Codegen.pm` | `transpiler/codegen.rb` (emits **Ruby**) | B |
| `KernelCache.pm` | `kernel_cache.rb` | C |
| `PassRunner.pm` | `pass_runner.rb` | C |
| `DrawOps.pm` | `draw_ops.rb` | C |
| `OverlayGen.pm` | `overlay_gen.rb` | C |
| `Renderer.pm` | `renderer.rb` | C |
| `Adapters.pm` | `adapters.rb` | C |
| `PNG.pm` | `png.rb` | D |
| `DSL.pm` | `dsl.rb` | D |
| `bin/make-noise` | `cli.rb` + `exe/noisemaker-rb` | D |
| `Transpiler/CDN.pm` | `transpiler/cdn.rb` | E |
| `Transpiler/Build.pm` | `transpiler/build.rb` | E |
| `scripts/build-bundle.pl` | `scripts/build-bundle.rb` | E |
| `scripts/parity.pl` | `scripts/parity.rb` | E |

Tests (`test/`, minitest):

| Source | Ruby test | Worker |
|---|---|---|
| `t/01-uintmath.t` | `test/test_uint_math.rb` | A |
| `t/02-primitives.t` | `test/test_primitives.rb` | A |
| `t/03-runtime.t` | `test/test_runtime.rb` | A |
| `t/04-kernel-smoke.t` | `test/test_kernel_smoke.rb` | C |
| `t/05-parity.t` | `test/test_parity.rb` | E |
| `t/06-dsl.t` | `test/test_dsl.rb` | D |
| `t/07-cli.t` | `test/test_cli.rb` | D |
| python `tests/test_png.py` | `test/test_png.rb` | D |
| python `tests/test_transpiler.py` | `test/test_transpiler.rb` | B |

Coordinator owns: `lib/noisemaker_cpu.rb` (facade), `version.rb`, gemspec,
`Gemfile`, `Rakefile`, `LICENSE`, `README.md`, `.gitignore`, this doc.

## Bundle layout (generated — never hand-edited)

```
lib/noisemaker_cpu/bundle/
├── metadata.json        # language-neutral; content-identical to perl/python's
├── bundle-lock.json     # sha256 per "<effect>:<program>" — MUST equal perl's
└── kernels/ruby/<namespace>__<effect>__<program>.rb   # 211 files
```

CDN fetches cache to `.cdn-cache/<version>/` (gitignored, extracted JSON),
seedable from the python port's cache — mirror `Transpiler/CDN.pm` exactly.

## Kernel ABI

A generated kernel file is a Ruby expression: assigns a lambda, ends with a
hash literal (the file's value when `eval`'d). Perl's `filter/invert`
translated — this exact style is normative for Codegen (B), Runtime (A), and
KernelCache/PassRunner (C):

```ruby
# Generated by NoisemakerCpu::Transpiler - do not edit.
run_pixel = lambda do |ctx, out|
  rt = ctx.rt
  u = ctx.uniforms
  g = {}
  main__void = nil
  _u_inputTex = ctx.texture_binding('inputTex')
  _u_mode = u.key?('mode') ? u['mode'] : 0
  g['fragColor'] = rt.construct(4, 0.0)
  main__void = lambda do
    color = nil; texSize = nil; uv = nil
    texSize = rt.texture_size(_u_inputTex)
    uv = rt.binary('/', rt.swizzle(ctx.frag_coord, 'xy'), rt.construct(2, texSize), 2, 'float')
    color = rt.texture(_u_inputTex, uv)
    if rt.bool(rt.binary('==', _u_mode, rt.i(1)))
      color = rt.assign_swizzle(color, 'rgb', rt.component_wise('min', rt.swizzle(color, 'rgb'), rt.binary('-', rt.f(1), rt.swizzle(color, 'rgb'), 3, 'float')))
    else
      color = rt.assign_swizzle(color, 'rgb', rt.binary('-', rt.f(1), rt.swizzle(color, 'rgb'), 3, 'float'))
    end
    g['fragColor'] = color.map { |c| rt.f32(c) }
  end
  main__void.call
  c = g['fragColor']
  out[0] = rt.f32(c[0]); out[1] = rt.f32(c[1]); out[2] = rt.f32(c[2]); out[3] = rt.f32(c[3])
end
{ kernel: run_pixel, uses_derivatives: false }
```

Rules:

- **`rt` method surface = perl's `Runtime.pm`, names unchanged.** Worker A
  implements every method perl's kernels call (derive the complete set with
  `grep -ho '$rt->[a-z_0-9]*' bundle/kernels/perl/*.pl | sort -u` over the perl
  bundle, plus everything `Runtime.pm` defines). Worker B's codegen emits only
  those names.
- **`ctx` surface = what perl kernels touch** (`$ctx->rt`, `$ctx->uniforms`,
  `$ctx->texture_binding(...)`, `$ctx->{frag_coord}`, …). Worker C derives the
  complete set the same way (`grep -ho '$ctx->[{a-z_]*' …`) and implements ctx
  as a small class with reader methods (hash-accesses like `->{frag_coord}`
  become the reader `ctx.frag_coord`). Worker B emits reader-method calls.
- Vectors are plain Ruby `Array`s of numerics; copies are explicit (`.dup`,
  `.map`). GLSL bools are Integer 0/1 **in values** (see trap #1).
- Kernel-internal state dict `g` and uniforms use **string** keys.
- The trailing hash uses symbol keys and Ruby booleans:
  `{ kernel: run_pixel, uses_derivatives: true|false }`.
- Loading: `KernelCache` evals kernel source in a **fresh empty binding** per
  load (`def self.empty_binding; binding; end`) and caches the resulting hash —
  mirror perl's `KernelCache.pm` semantics (LRU, keying) exactly. Never
  `TOPLEVEL_BINDING(.dup)`: `Binding#dup` shares the host script's local
  environment, so kernel locals like `size`/`seed` would clobber host locals
  (observed live during integration).

## The Ruby traps (read twice)

1. **`0` is truthy in Ruby.** Perl kernels/runtime pass GLSL bools around as
   Integer 0/1 and `if (0)` is false in Perl — not in Ruby. Pin: rt
   comparison/logical ops **keep returning Integer 0/1** exactly like perl (so
   all value plumbing is identical), and **every condition context** the
   codegen emits (`if`, `while`, ternary, `&&`, `||`, `!`) goes through
   `rt.bool(expr)` (`x != 0`, accepting Integer or Float). Runtime-internal
   Ruby code must apply the same discipline wherever it branches on a GLSL
   bool value. Grep your own output for bare numeric conditions before
   reporting done.
2. **Integer division.** Ruby `Integer/Integer` truncates; Perl `/` is always
   float. Wherever `Runtime.pm` (or any perl module) relies on native float
   `/`, use `.fdiv`/`.to_f`. GLSL `int/int` truncation must go through the
   same explicit path perl uses — never accidentally via Ruby's `/`.
3. **`%` vs fmod.** Perl `%` and Ruby `%` both follow the divisor's sign —
   translate directly. `POSIX::fmod` (C-truncated) → `Float#remainder`.
   `glsl_mod` stays the explicit `x - y*floor(x/y)` helper. Never conflate.
4. **float32:** `f32(x)` = `[x].pack('e').unpack1('e')` (little-endian
   single). Preserve perl's non-finite handling bit-for-bit.
5. **uint32:** Ruby Integers are arbitrary-precision — nothing wraps. Mask
   `& 0xFFFFFFFF` after every unsigned op exactly as `UintMath.pm` does.
6. **String keys** for all data plumbing (uniforms, metadata, texture maps) —
   `JSON.parse` yields strings; never mix in symbols there.
7. **POSIX map:** `POSIX::log2`→`Math.log2`, `atan2`→`Math.atan2`, 1-arg
   `atan`→`Math.atan`, `POSIX::trunc`→`.truncate`, `floor`/`ceil`→
   `Math.floor`/`Math.ceil` — but match perl's *numeric type* expectations
   (perl floor returns a float; Ruby `Integer#floor` differs from
   `Math.floor`).
8. **No aliasing:** copy where perl copies (`[@$v]` → `v.dup`); never let an
   out-buffer alias an input across pixels.
9. **`sort` stability/comparators:** where perl sorts numerically
   (`sort { $a <=> $b }`), use `sort_by`/explicit comparator — Ruby default
   `sort` on mixed floats is fine but be explicit to preserve order semantics.

## Float-model canary vectors (must pass early)

| Expression | Expected |
|---|---|
| `pcg3d([1,2,3])` | `[4204755366, 1223881804, 1500469937]` |
| `hash_uint32(0x1234abcd)` | `737574769` |
| `umul(0xffffffff, 374761393)` | `3920205903` |
| `glsl_mod(-1, 3)` | `2` |
| `uint32(-1)` | `4294967295` |
| `float(0xffffffff)` | `4294967296.0` |
| `filter/invert` on `[0.2, 0.4, 0.8, 0.5]` | `[0.80000001, 0.60000002, 0.19999999, 0.5]` (f32) |

The full golden set lives in the perl `t/` files you are mirroring — port
every assertion, adjusting only syntax.

## Tests

- Each `test/test_*.rb` is self-contained:
  `require "minitest/autorun"` + `require_relative "../lib/noisemaker_cpu"`
  (transpiler tests require `../lib/noisemaker_cpu/transpiler/...` directly).
- Run: `cd /Users/alex/platform/noisemaker-for-ruby && /opt/homebrew/opt/ruby/bin/ruby -Ilib test/test_<name>.rb`
- The parity harness contract (worker E): same flags and behavior as
  `scripts/parity.pl` — `--only id,id`, `--size N`, JS oracle located via
  `NOISEMAKER_CPU_DIR` env (default `../noisemaker-cpu`), summary line format
  `=== PARITY: N/167 pass (<=2) | ... ===`.

## Worker rules

- Touch **only your assigned files**. Coordinator files and other workers'
  files are off-limits — report integration needs instead of editing.
- **No git commands.** The coordinator commits.
- **No network calls** — except the code you *write* for `transpiler/cdn.rb`
  (worker E), whose *tests* must run offline (seed `.cdn-cache/` from
  `/Users/alex/platform/noisemaker-for-python/.cdn-cache` if present, else
  skip network-dependent assertions and flag it).
- **Foreground to completion.** Never launch a sweep in the background and
  end your turn "to resume later" — that is a failed task. Block and wait.
- Report back: files written (+ line counts), exact test command(s) run with
  the output tail, and every deviation, ambiguity, or JS-vs-perl dispute you
  hit. Claim only what a command you ran actually shows.
