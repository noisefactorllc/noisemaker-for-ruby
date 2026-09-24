<!-- repo-hero -->
<a href="https://noisemaker.app/"><img src="docs/hero.jpg" alt="Noisemaker for CPU (Ruby)" width="100%"></a>

<sub>Open source from <a href="https://noisefactor.io">Noise Factor</a> &middot; <a href="https://github.com/noisefactorllc">more projects</a></sub>

# noisemaker-for-ruby

Current measured support: [compatibility report](docs/COMPATIBILITY.md).

Current qualification limits: [completion gaps](docs/COMPLETION_GAPS.md).

> This package supports the "Export Shader Pipeline" feature in Noisedeck.app. The feature runs shader compositions on other platforms. Noise Factor derives this package from the upstream Noisemaker Engine project and tests it for pixel-level parity.

This is not a classic noise library. This is a new effort centered around
software shader execution.

A pure-Ruby CPU implementation of the [Noisemaker](https://noisemaker.app)
shader engine — the Ruby port of [`noisemaker-for-cpu`](https://github.com/noisefactorllc/noisemaker-for-cpu),
sibling to the [Python](https://github.com/noisefactorllc/noisemaker-for-python)
and [Perl](https://github.com/noisefactorllc/noisemaker-for-perl) ports.

Effect kernels are **transpiled directly from the upstream GLSL** served by the `shaders.noisedeck.app` CDN (sha256-locked). They are not hand-maintained. A pure-Ruby GLSL ES 3.00 front end lexes, preprocesses, parses, and emits a Ruby kernel per shader pass. A float32-faithful runtime reproduces the reference engine's arithmetic:

- Float32 register rounding.
- Half-float render-target quantization.
- GLSL uint32 wraparound with bit-exact PCG hashing.
- Screen-space derivatives.
- GL texture sampling.

The bundle includes 205 catalog effects (289 kernels). The parity harness
compares exact RGBA8 output with a pinned JavaScript reference. It uses 8×8
images, seed 1, time 0.25, small volume atlases, and identical explicit scenes
for particle consumers. These checks cover the catalog, not every parameter,
resolution, or animation. Iterated scenes also have separate integration tests.

This implementation is useful for offline rendering and running exported
Noisedeck compositions in Ruby without native extensions or a GPU. It is an
interpreter, and shader-heavy effects are slow: a warm 32×32 `synth/curl` render
allocated about 24 million objects and took several seconds on the development
machine with Ruby 4.0. Start at 32×32 before increasing resolution. Real-time
playback and large production renders are not its practical target.

## Install

Core stdlib only — no runtime gem dependencies. Ruby 3.2+.

```bash
gem build noisemaker-for-ruby.gemspec
gem install noisemaker-for-ruby-0.0.0.gem
```

The build also works from a source archive without a `.git` directory.
For Bundler, add `gem "noisemaker-for-ruby", path: "/path/to/checkout"` to your
Gemfile. Both `require "noisemaker-for-ruby"` and `require "noisemaker_cpu"` load
the engine. There are no runtime network requests.

Or run directly from a checkout: `ruby -Ilib exe/noisemaker-rb ...`.

## Render an effect

Discover effects and their parameters without reading generated code:

```bash
noisemaker-rb effects
noisemaker-rb effects filter/
noisemaker-rb describe synth/curl
```

CLI examples use small images deliberately. The existing command defaults are
1024×1024 for `generate` and 512×512 for `run` and `animate`; pass dimensions
explicitly for an initial render.

```bash
noisemaker-rb generate synth/solid --width 64 --height 64 --param 'color=#4080c0' --filename solid.png
noisemaker-rb generate synth/curl --width 32 --height 32 --seed 1 --param scale=16 --filename curl.png
noisemaker-rb apply filter/lighting curl.png --filename lit.png

# Needs ffmpeg for MP4; saved PNGs are retained if ffmpeg is unavailable.
noisemaker-rb animate synth/solid --width 32 --height 32 --frame-count 4 --save-frames frames --filename solid.mp4

# Render a Polymorphic DSL program from stdin.
printf 'search synth, filter\nnoise(seed: 3, ridges: true).vignette().write(o0)\nrender(o0)\n' |
  noisemaker-rb run --width 32 --height 32 --filename noise.png
```

Image input and output are PNG. MP4 encoding requires an `ffmpeg` executable
on `PATH`; the renderer itself has no external runtime dependencies.

Library:

```ruby
require "noisemaker-for-ruby"

renderer = NoisemakerCpu::Renderer
surface = renderer.render_effect(
  "synth/curl", { scale: 16, ridges: false }, nil,
  width: 32, height: 32, seed: 1
)
File.binwrite("curl.png", NoisemakerCpu::PNG.encode_png(surface))

# A filter consumes a Surface through the inputs Hash. Surface parameters
# defaulting to inputTex, such as lighting's heightMap, use this image.
filtered = renderer.render_effect(
  "filter/lighting", {}, { inputTex: surface }, width: 32, height: 32
)
File.binwrite("lit.png", NoisemakerCpu::PNG.encode_png(filtered))
```

Parameter and input keys accept strings or symbols. Booleans accept
`true`/`false`, `1`/`0`, and the corresponding CLI spellings `yes`/`no` or
`on`/`off`. Enum parameters accept the names or numeric values printed by
`describe`. Colors accept RGB(A) arrays or hex strings; vectors accept numeric
arrays or comma-separated CLI values. Invalid names and values raise
`ArgumentError` with the effect and parameter identified. Metadata slider
ranges are hints, not clamps; `volumeSize` and `stateSize` accept custom positive
sizes as well as their named presets.

Bind explicit surface overrides in the inputs Hash, for example
`{ inputTex: surface, heightMap: another_surface }`. Set `heightMap: nil` to
leave it unbound; the equivalent DSL argument is `heightMap: none`.
Use `Renderer.render_dsl(program, width: 32, height: 32, seed: 1)` for multi-effect
compositions, including particle and volume pipelines. Methods prefixed with
`_` and generated kernel files are implementation details.

## Regenerating the bundle

The vendored kernels + metadata under `lib/noisemaker_cpu/bundle/` are
generated from the CDN (cached to `.cdn-cache/`, sha256-locked in
`bundle-lock.json`):

```bash
ruby scripts/build-bundle.rb --all
```

Builds are staged and validated before replacing the installed bundle. Fetch,
compile, or lock-drift errors leave the previous bundle intact. An intentional
source update requires `--update-lock`; review both the generated changes and
the parity results before publishing. `--only id,id` builds a subset bundle,
so use `--all` when regenerating the shipped catalog.

## Tests

```bash
bundle install
bundle exec rake test
```

A standalone checkout runs unit, CLI, archive-installation, and regression
tests. Only external checks skip when their dependencies are unavailable:
JavaScript parity needs the pinned reference checkout and Node 22+, video
verification needs ffmpeg/ffprobe, and live CDN checks are opt-in through
`NOISEMAKER_LIVE_CDN=1`.

`scripts/oracle-lock.json` records the exact JavaScript repository revision
and source identity. Place that revision in a sibling `noisemaker-for-cpu`
checkout, or set `NOISEMAKER_CPU_DIR` to its path. A changed or dirty reference
is rejected; upgrading it requires an explicit lock update and parity review.

```bash
NOISEMAKER_REQUIRE_ORACLE=1 bundle exec rake test
bundle exec ruby scripts/parity.rb
# A focused check, useful during development:
bundle exec ruby scripts/parity.rb --only synth/curl,filter/lighting
```

The harness fails on any pixel difference, runtime failure, missing oracle,
or unknown selection. Required CI checks run Ruby 3.2, 3.3, 3.4 and 4.0 on
Linux, Ruby 4.0 on macOS, archive installation under Bundler, C-locale
rendering, video frame counts, and all 205 reference comparisons. Export-kit
publication waits for those checks. Live CDN checks are separate from this
reproducible gate and may require `NOISEMAKER_PERL_LOCK` for cross-port lock checks.

## License

MIT © Noise Factor LLC. See [LICENSE](LICENSE).
