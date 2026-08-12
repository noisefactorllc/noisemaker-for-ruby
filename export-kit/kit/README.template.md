# {{NM_PROGRAM_NAME}}

Your program, exported from Noisedeck as a Ruby package that renders it **on the CPU**. No GPU, no
OpenGL, no native gem: `engine/` is the whole engine, it uses nothing outside Ruby's standard
library, and Ruby executes what would normally be shader code as ordinary Ruby, one pixel at a time.
It fetches nothing at runtime.

That makes this the export with no install step at all — `bundle install` has nothing to do here —
and the slow way to draw a frame. A GPU colors thousands of pixels at once; this walks them.

## Run it

You need **Ruby 3.2 or newer**. Nothing else. Unzip this folder, open a terminal in it, and start
small:

```sh
ruby run.rb program.dsl --width 64 --height 64 --output out.png
```

That writes a 64×64 `out.png` beside your program, which is enough to prove the export works. Then
scale up:

```sh
ruby run.rb program.dsl --width 512 --height 512 --output art.png
```

Time grows with the pixel count, and pure Ruby walks every one of them, so raise the size in steps
and expect a large frame to take a while.

`--seed N` picks the deterministic seed and `--time N` the normalized time, for effects that animate.
`ruby run.rb --help` lists everything.

## What's inside

| Path | What it is |
| --- | --- |
| `run.rb` | The entry point. Puts `engine/lib` on the load path and renders. This is the file you run. |
| `program.dsl` | Your program's source, exactly as Noisedeck had it. |
| `engine/lib/` | The engine: DSL parser, effect catalog, and the transpiled kernels. |
| `engine/exe/noisemaker-rb` | The port's own command line tool, with subcommands beyond rendering a file. |
| `noisedeck-export.json` | What was exported, when, against which engine build. |
| `LICENSES/` | Licenses for everything shipped here. |

Nothing is installed and nothing is written outside this folder. `run.rb` puts `engine/lib` at the
front of `$LOAD_PATH`, so an unrelated `noisemaker_cpu` on the system cannot shadow the one that
shipped with your program.

`engine/exe/noisemaker-rb` resolves `engine/lib` relative to itself, so it works from here too. It
renders one catalog effect at a time (`generate`, `apply`, `animate`) and takes a whole program on
standard input:

```sh
ruby engine/exe/noisemaker-rb run --width 512 --height 512 --filename art.png < program.dsl
```

`ruby engine/exe/noisemaker-rb --help` covers the rest. For the program sitting beside it, `run.rb`
is the shorter way to say the same thing.

## The engine

The port ships inside this export, so it runs offline as it stands. It is also a normal gem —
`NoisemakerCpu::Renderer.render_dsl(source, width:, height:)` and `NoisemakerCpu::PNG.encode_png` are
the two calls `run.rb` makes, and you can make them the same way from your own code.
<https://github.com/noisefactorllc/noisemaker-for-ruby> documents the rest.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The Ruby port is a second
implementation of that engine rather than the same code, so expect small differences from what the
app showed you.

## Editing it

Replace `program.dsl` with anything the Noisemaker language accepts, as long as its effects are in
the supported set below, and run the same command again. To render several variations, call
`render_dsl` in a loop of your own rather than paying process startup each time.

## Effects used by this program

{{NM_EFFECT_LIST}}

## What this port cannot render

Five effects from the upstream catalog: `synth/roll`, `synth/scope` and `synth/spectrum`, which react
to live audio, and `render/meshLoader` and `render/meshRender`, which need a mesh pipeline. Everything
else in the catalog renders here, and `engine/lib/noisemaker_cpu/bundle/metadata.json` lists exactly
what the engine in this folder carries.

To check an edited `program.dsl` against a different build of this port, put it back into Noisedeck
and open the export dialog with Ruby selected: it marks any effect the port cannot render before you
export again.

## License

The Noisemaker engine and the Ruby port are MIT licensed; see `LICENSES/`. Your program and the
imagery it renders are yours.
