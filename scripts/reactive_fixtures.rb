# frozen_string_literal: true

# Shared deterministic external-input fixtures for the five reactive/mesh
# authority cases (synth/roll, synth/scope, synth/spectrum, render/meshLoader,
# render/meshRender). Byte-identical port of the pinned oracle's
# scripts/parity/reactive-fixtures.js:
#
#   - MIDI channel 1 C-major triad (60/64/67, velocities 100/80/90), channel 2
#     low C (48, velocity 64), then 24 clock pulses
#   - audio waveform 0.5+0.5*sin(2*pi*3*i/128) and spectrum (1-i/127)^2
#     (128 samples)
#   - a 12-triangle cube OBJ packed into 256x256 RGBA mesh textures
#
# Both engines run the exact DSL program the oracle repo's parity fixtures
# run, with these fixtures bound (scripts/parity.rb's default gate and the
# extended scripts/parity-sweep.rb cases alike). The DSL sources live here so
# the sweep can qualify the same cases with nondefault parameters by
# injecting keyword arguments into the effect call.

require_relative "../lib/noisemaker_cpu/external_input"

EXTERNAL_INPUT_SOURCES = {
  "synth/roll" => "search synth\n\nroll()\n.write(o0)\n\nrender(o0)\n",
  "synth/scope" => "search synth\n\nscope()\n.write(o0)\n\nrender(o0)\n",
  "synth/spectrum" => "search synth\n\nspectrum()\n.write(o0)\n\nrender(o0)\n",
  "render/meshLoader" => "search render\n\nmeshLoader().write(o0)\n\nrender(o0)\n",
  "render/meshRender" => "search render\n\nmeshLoader()\n  .meshRender()\n  .write(o0)\n\nrender(o0)\n",
}.freeze

REACTIVE_FIXTURES = begin
  midi_state = NoisemakerCpu::ExternalInput::MidiState.new
  midi_messages = [
    [0x90, 60, 100], [0x90, 64, 80], [0x90, 67, 90],
    [0x91, 48, 64],
  ] + Array.new(24) { [0xf8] }
  midi_messages.each { |message| midi_state.handle_message(message) }
  midi_state.update_note_grid

  audio_state = NoisemakerCpu::ExternalInput::AudioState.new
  audio_state.set_waveform(Array.new(128) { |i| 0.5 + 0.5 * Math.sin((2 * Math::PI * 3 * i) / 128) })
  audio_state.set_spectrum(Array.new(128) { |i| (1 - i / 127.0)**2 })

  cube_obj = [
    "v -0.7 -0.7 -0.7", "v 0.7 -0.7 -0.7", "v 0.7 0.7 -0.7", "v -0.7 0.7 -0.7",
    "v -0.7 -0.7 0.7", "v 0.7 -0.7 0.7", "v 0.7 0.7 0.7", "v -0.7 0.7 0.7",
    "vn 0 0 -1", "vn 0 0 1", "vn 0 -1 0", "vn 0 1 0", "vn -1 0 0", "vn 1 0 0",
    "f 1//1 2//1 3//1 4//1", "f 5//2 8//2 7//2 6//2", "f 1//3 5//3 6//3 2//3",
    "f 2//4 6//4 7//4 3//4", "f 3//5 7//5 8//5 4//5", "f 4//6 8//6 5//6 1//6",
    "",
  ].join("\n")
  parsed = NoisemakerCpu::ExternalInput.parse_obj(cube_obj)
  mesh_data = NoisemakerCpu::ExternalInput.pack_mesh_data_for_textures(
    parsed["positions"], parsed["normals"], parsed["uvs"], 256, 256
  ).merge("texWidth" => 256, "texHeight" => 256)

  {
    "synth/roll" => { "midiState" => midi_state },
    "synth/scope" => { "audioState" => audio_state },
    "synth/spectrum" => { "audioState" => audio_state },
    "render/meshLoader" => { "meshData" => mesh_data },
    "render/meshRender" => { "meshData" => mesh_data },
  }.freeze
end

# External-input DSL source for one case: the shared program with the case's
# nondefault parameters injected into the effect call. Effects without
# parameters (render/meshLoader) render the shared program unchanged.
def external_input_source_for(effect_id, params)
  source = EXTERNAL_INPUT_SOURCES.fetch(effect_id)
  return source if params.empty?

  func = NoisemakerCpu::Renderer.meta["effects"].fetch(effect_id)["func"]
  args = params.map { |name, value| "#{name}: #{value.inspect}" }.join(", ")
  call = "#{func}()"
  raise "external-input source #{effect_id} has no #{call} call site" unless source.include?(call)
  source.sub(call, "#{func}(#{args})")
end
