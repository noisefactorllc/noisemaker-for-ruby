# {{NM_PROGRAM_NAME}}

This Ruby package exports your Noisedeck program to render **on the CPU**. It requires no GPU, OpenGL, or native gem. `engine/` contains the whole engine and uses only Ruby's standard library. Ruby executes the shader code as ordinary Ruby, one pixel at a time. It fetches nothing at runtime.

This export requires no install step, including `bundle install`. It is a slow way to draw a frame. A GPU colors thousands of pixels at once. This renderer processes them one at a time.

## Run it

You need **Ruby 3.2 or newer** and no other dependencies. Unzip this folder. Open a terminal in it. Start with a small image:

```sh
ruby run.rb program.dsl --width 64 --height 64 --output out.png
```

The command writes a 64×64 `out.png` beside your program. This checks that the export works. Then increase the output size:

```sh
ruby run.rb program.dsl --width 512 --height 512 --output art.png
```

Rendering time increases with the pixel count because pure Ruby processes every pixel. Increase the size gradually. Expect large frames to take longer.

`--seed N` selects the deterministic seed. `--time N` sets the normalized time for effects that animate.
`ruby run.rb --help` lists everything.

## What's inside

| Path | What it is |
| --- | --- |
| `run.rb` | The entry point. Puts `engine/lib` on the load path and renders. This is the file you run. |
| `program.dsl` | Your program's source, exactly as it was in Noisedeck. |
| `engine/lib/` | The engine: DSL parser, effect catalog, and the transpiled kernels. |
| `engine/exe/noisemaker-rb` | The port's own command line tool, with subcommands beyond rendering a file. |
| `noisedeck-export.json` | The exported content, export time, and engine build. |
| `LICENSES/` | Licenses for everything shipped here. |

The export installs nothing and writes nothing outside this folder. `run.rb` places `engine/lib` first in `$LOAD_PATH`. An unrelated `noisemaker_cpu` on the system cannot override the copy included with your program.

`engine/exe/noisemaker-rb` resolves `engine/lib` relative to itself, so it works from here too. It
renders one catalog effect at a time (`generate`, `apply`, `animate`) and takes a whole program on
standard input:

```sh
ruby engine/exe/noisemaker-rb run --width 512 --height 512 --filename art.png < program.dsl
```

`ruby engine/exe/noisemaker-rb --help` covers the rest. For the program sitting beside it, `run.rb`
is the shorter way to say the same thing.

## The engine

The export includes the port and runs offline without changes. It is also a normal gem. `run.rb` calls two functions: `NoisemakerCpu::Renderer.render_dsl(source, width:, height:)` and `NoisemakerCpu::PNG.encode_png`. You can call them the same way from your own code.
<https://github.com/noisefactorllc/noisemaker-for-ruby> documents the rest.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The Ruby port is a separate implementation of that engine. Expect small differences from the app output.

## Editing it

Replace `program.dsl` with a Noisemaker program that uses only the supported effects listed below. Run the same command again. To render several variations, call `render_dsl` in a loop in your own code. This avoids process startup for each variation.

## Effects used by this program

{{NM_EFFECT_LIST}}

## What this port cannot render

This port cannot render five effects from the upstream catalog:

- `synth/roll`, `synth/scope` and `synth/spectrum` react to live audio.
- `render/meshLoader` and `render/meshRender` need a mesh pipeline.

Everything else in the catalog renders here.
`engine/lib/noisemaker_cpu/bundle/metadata.json` lists exactly which effects this engine contains.

To check an edited `program.dsl` against a different build of this port:

1. Import the program into Noisedeck.
2. Open the export dialog.
3. Select Ruby.

Before you export again, the dialog marks any effect the port cannot render.

## License

The Noisemaker engine and the Ruby port are MIT licensed. See `LICENSES/`. Your program and the
imagery it renders are yours.
