# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/noisemaker_cpu/external_input"
require_relative "../lib/noisemaker_cpu/mesh_render"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/cli"

# External-input state for the reactive (MIDI/audio) and mesh (OBJ) effects:
# port of noisemaker-cpu src/runtime/external-input.js and
# src/runtime/external-textures.js, delivered by the b0e6c4130ac2 sync.
class TestExternalInput < Minitest::Test
  CUBE_OBJ = [
    "v -0.7 -0.7 -0.7", "v 0.7 -0.7 -0.7", "v 0.7 0.7 -0.7", "v -0.7 0.7 -0.7",
    "v -0.7 -0.7 0.7", "v 0.7 -0.7 0.7", "v 0.7 0.7 0.7", "v -0.7 0.7 0.7",
    "vn 0 0 -1", "vn 0 0 1", "vn 0 -1 0", "vn 0 1 0", "vn -1 0 0", "vn 1 0 0",
    "f 1//1 2//1 3//1 4//1", "f 5//2 8//2 7//2 6//2", "f 1//3 5//3 6//3 2//3",
    "f 2//4 6//4 7//4 3//4", "f 3//5 7//5 8//5 4//5", "f 4//6 8//6 5//6 1//6",
    "",
  ].join("\n")

  def midi_fixture
    midi_state = NoisemakerCpu::ExternalInput::MidiState.new
    messages = [
      [0x90, 60, 100], [0x90, 64, 80], [0x90, 67, 90],
      [0x91, 48, 64],
    ] + Array.new(24) { [0xf8] }
    messages.each { |message| midi_state.handle_message(message) }
    midi_state.update_note_grid
    midi_state
  end

  def test_midi_state_routes_notes_clock_and_grid
    midi = midi_fixture
    assert_equal 24, midi.clock_count
    channel1 = midi.get_channel(1)
    assert_equal 1, channel1.gate
    assert_equal 100, channel1.keys[60]
    assert_equal 80, channel1.keys[64]
    assert_equal 90, channel1.keys[67]
    assert_equal 64, midi.get_channel(2).keys[48]
    assert_equal 0, midi.get_channel(3).gate
    # Grid row 0 is channel 1: R = velocity/127, G = gate, B = A = 0.
    assert_in_delta 100 / 127.0, midi.note_grid[60 * 4], 1e-6
    assert_equal 1.0, midi.note_grid[60 * 4 + 1]
    assert_equal 0.0, midi.note_grid[60 * 4 + 2]
    assert_equal 0.0, midi.note_grid[60 * 4 + 3]
    # Unrouted status bytes are ignored.
    assert_equal -1, midi.handle_message([0xf0, 1])
    # All-notes-off clears gate and keys.
    midi.handle_message([0xb0, 123, 0])
    assert_equal 0, channel1.gate
    assert_equal 0, channel1.keys[60]
  end

  def test_audio_state_stores_f32_arrays
    audio = NoisemakerCpu::ExternalInput::AudioState.new
    waveform = Array.new(128) { |i| 0.5 + 0.5 * Math.sin((2 * Math::PI * 3 * i) / 128) }
    spectrum = Array.new(128) { |i| (1 - i / 127.0)**2 }
    audio.set_waveform(waveform)
    audio.set_spectrum(spectrum)
    assert_equal 128, audio.waveform.length
    assert_equal 0.5, audio.waveform[0]
    # f32 storage: every stored value is float32-representable.
    audio.waveform.each { |v| assert_equal NoisemakerCpu::ExternalInput._f32(v), v }
    audio.spectrum.each { |v| assert_equal NoisemakerCpu::ExternalInput._f32(v), v }
    assert_in_delta 1.0, audio.spectrum[0], 1e-6
    assert_raises(RangeError) { audio.set_waveform(Array.new(127, 0.5)) }
    assert_raises(RangeError) { audio.set_spectrum(Array.new(129, 0.5)) }
  end

  def test_parse_obj_fan_triangulates_with_reversed_winding
    parsed = NoisemakerCpu::ExternalInput.parse_obj(CUBE_OBJ)
    # 6 quad faces -> 12 triangles -> 36 de-indexed vertices, 1-based OBJ
    # indices, fan order (f0, f[i+1], f[i]) reversed per triangle.
    assert_equal 36, parsed["vertexCount"]
    f32 = ->(v) { NoisemakerCpu::ExternalInput._f32(v) }
    assert_equal [-0.7, -0.7, -0.7].map(&f32), parsed["positions"][0, 3] # f 1 (face 1 corner 1)
    assert_equal [0.7, 0.7, -0.7].map(&f32), parsed["positions"][3, 3] # f 3
    assert_equal [0.7, -0.7, -0.7].map(&f32), parsed["positions"][6, 3] # f 2
    # Per-face normals from the vn references.
    assert_equal [0.0, 0.0, -1.0], parsed["normals"][0, 3]
    assert_equal [0.0, 0.0, 1.0], parsed["normals"][18, 3] # face 2 (vn 2)
  end

  def test_parse_obj_computes_smooth_normals_without_vn
    obj = ["v 0 0 0", "v 1 0 0", "v 0 1 0", "f 1 2 3", ""].join("\n")
    parsed = NoisemakerCpu::ExternalInput.parse_obj(obj)
    assert_equal 3, parsed["vertexCount"]
    # Reversed winding flips the face normal to -z.
    assert_in_delta -1.0, parsed["normals"][2], 1e-6
  end

  def test_pack_mesh_data_marks_valid_vertices
    parsed = NoisemakerCpu::ExternalInput.parse_obj(CUBE_OBJ)
    packed = NoisemakerCpu::ExternalInput.pack_mesh_data_for_textures(
      parsed["positions"], parsed["normals"], parsed["uvs"], 256, 256
    )
    assert_equal 256 * 256 * 4, packed["positionData"].length
    assert_equal 36, packed["vertexCount"]
    assert_equal 1.0, packed["positionData"][3] # w = 1 marks a valid vertex
    assert_equal 0.0, packed["positionData"][36 * 4 + 3] # tail texels w = 0
  end

  def test_flip_rgba_rows_reverses_row_order
    data = (0...16).map { |i| i.to_f } # 2 rows x 2 texels (row stride 8)
    flipped = NoisemakerCpu::ExternalInput.flip_rgba_rows(data, 2, 2)
    assert_equal data[8, 4], flipped[0, 4] # surface row 0 = original bottom row
    assert_equal data[0, 4], flipped[8, 4]
  end

  def test_external_data_surface_is_rgba32f_nearest
    surf = NoisemakerCpu::ExternalInput.external_data_surface(
      (0...8).map(&:to_f), 1, 2
    )
    assert_equal "rgba32f", surf.format
    assert_equal "nearest", surf.filter
    assert_equal 1, surf.width
    assert_equal 2, surf.height
  end

  def test_renderer_binds_reactive_defaults_and_requires_mesh_data
    # No external state: reactive uniforms zero-bind like WebGL uniform arrays.
    scope = NoisemakerCpu::Renderer.render_effect("synth/scope", {}, nil, width: 4, height: 4)
    assert_equal 64, scope.to_rgba8.bytesize
    # Mesh effects refuse to render without external mesh data.
    error = assert_raises(RuntimeError) do
      NoisemakerCpu::Renderer.render_effect("render/meshRender", {}, nil, width: 4, height: 4)
    end
    assert_match(/requires external mesh data/, error.message)
  end

  def test_reactive_dsl_cases_render_with_fixtures
    NoisemakerCpu::Renderer.render_dsl(
      "search synth\n\nscope()\n.write(o0)\n\nrender(o0)\n",
      width: 4, height: 4, seed: 1, time: 0.25,
      external_inputs: { "audioState" =>
        begin
          audio = NoisemakerCpu::ExternalInput::AudioState.new
          audio.set_waveform(Array.new(128) { |i| (i % 8) / 8.0 })
          audio.set_spectrum(Array.new(128) { |i| (i % 4) / 4.0 })
          audio
        end }
    )
    NoisemakerCpu::Renderer.render_dsl(
      "search synth\n\nroll()\n.write(o0)\n\nrender(o0)\n",
      width: 4, height: 4, seed: 1, time: 0.25,
      external_inputs: { "midiState" => midi_fixture }
    )
    parsed = NoisemakerCpu::ExternalInput.parse_obj(CUBE_OBJ)
    mesh = NoisemakerCpu::ExternalInput.pack_mesh_data_for_textures(
      parsed["positions"], parsed["normals"], parsed["uvs"], 256, 256
    ).merge("texWidth" => 256, "texHeight" => 256)
    rendered = NoisemakerCpu::Renderer.render_dsl(
      "search render\n\nmeshLoader()\n  .meshRender()\n  .write(o0)\n\nrender(o0)\n",
      width: 4, height: 4, seed: 1, time: 0.25,
      external_inputs: { "meshData" => mesh }
    )
    assert_equal 64, rendered.to_rgba8.bytesize
  end

  def test_mesh_render_triangles_adapter_dispatches_by_key
    assert NoisemakerCpu::MeshRender.get_adapter("render/meshRender", "render"),
      "meshRender triangles adapter must be registered"
    assert_nil NoisemakerCpu::MeshRender.get_adapter("render/meshRender", "clear")
  end

  def test_cli_random_pool_excludes_external_input_effects
    # The random `effect` pool mirrors the oracle CLI's exclusion of the
    # external-input effects: without the exclusion the reactive generators
    # would be selectable, with it none of the five can be returned.
    effects = NoisemakerCpu::Renderer.meta["effects"]
    unguarded = effects.keys.select do |key|
      candidate = effects[key]
      (candidate["kind"] || "") == "generator" &&
        (candidate["domain"] || "image") == "image" &&
        !candidate["iterated"] && candidate["externalTexture"].nil?
    end
    reactive = unguarded & %w[synth/roll synth/scope synth/spectrum]
    assert_equal %w[synth/roll synth/scope synth/spectrum], reactive.sort,
      "the exclusion must be load-bearing: these generators would be selectable"
    guarded = unguarded - NoisemakerCpu::CLI::EXTERNAL_INPUT_EFFECT_IDS
    assert_empty guarded & NoisemakerCpu::CLI::EXTERNAL_INPUT_EFFECT_IDS
    20.times { NoisemakerCpu::CLI._resolve_effect("random", "generator") }
  end
end