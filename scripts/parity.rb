#!/usr/bin/env ruby
# frozen_string_literal: true

# Cross-language parity harness: render every bundled effect in Ruby vs the
# JS oracle (noisemaker-cpu `effect` CLI) at parity settings, and categorize.
#
# Usage: ruby scripts/parity.rb [--only id,id] [--size N] [--volume-size N]
#
require "fileutils"
require "tmpdir"
require "optparse"
require_relative "oracle"

require_relative "../lib/noisemaker_cpu/external_input"
require_relative "../lib/noisemaker_cpu/png"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/surface"

cpu_dir = NoisemakerOracle::ROOT
cli = NoisemakerOracle::CLI
oracle_error = begin
  NoisemakerOracle.verify!
  nil
rescue StandardError => error
  error.message
end

size = 8
seed = 1
render_time = 0.25
only = nil
volume_size = 16
OptionParser.new do |opts|
  opts.on("--only IDS") { |value| only = value.split(",").to_h { |id| [id, true] } }
  opts.on("--size N", Integer) { |value| size = value }
  opts.on("--volume-size N", Integer) { |value| volume_size = value }
end.parse!
abort "sizes must be positive integers" unless size.positive? && volume_size.positive?
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

tmp = Dir.mktmpdir
at_exit { FileUtils.remove_entry(tmp) }
ext_png = File.join(tmp, "ph_ext.png")
ext_tex = nil

# The five reactive/mesh authority cases (scripts/parity/reactive-fixtures.js
# on the CPU side): both engines run the exact DSL program the oracle repo's
# parity fixtures run, with the deterministic external-input fixtures bound.
EXTERNAL_INPUT_SOURCES = {
  "synth/roll" => "search synth\n\nroll()\n.write(o0)\n\nrender(o0)\n",
  "synth/scope" => "search synth\n\nscope()\n.write(o0)\n\nrender(o0)\n",
  "synth/spectrum" => "search synth\n\nspectrum()\n.write(o0)\n\nrender(o0)\n",
  "render/meshLoader" => "search render\n\nmeshLoader().write(o0)\n\nrender(o0)\n",
  "render/meshRender" => "search render\n\nmeshLoader()\n  .meshRender()\n  .write(o0)\n\nrender(o0)\n",
}.freeze

# Byte-identical port of scripts/parity/reactive-fixtures.js on the CPU side:
# MIDI channel 1 C-major triad (60/64/67, velocities 100/80/90), channel 2 low
# C (48, velocity 64), then 24 clock pulses; audio waveform
# 0.5+0.5*sin(2*pi*3*i/128) and spectrum (1-i/127)^2 (128 samples); a
# 12-triangle cube OBJ packed into 256x256 RGBA mesh textures.
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

# Deterministic non-uniform 8-bit texture for external-texture effects
# (text/media) -- a solid would hide texture-orientation/sampling divergence.
ext_texture = lambda do
  return ext_tex if ext_tex

  d = []
  (0...size).each do |y|
    (0...size).each do |x|
      d << x.fdiv([size - 1, 1].max) << y.fdiv([size - 1, 1].max) << ((x + y) % size).fdiv([size - 1, 1].max) << 1.0
    end
  end
  surf = NoisemakerCpu::Surface.new(size, size, d)
  File.binwrite(ext_png, NoisemakerCpu::PNG.encode_png(surf))
  ext_tex = NoisemakerCpu::PNG.decode_png(File.binread(ext_png))
  ext_tex
end

js_effect = lambda do |effect_id, out, input_png, params|
  raise oracle_error if oracle_error
  # The reactive/mesh cases bind deterministic external-input fixtures, which
  # the `effect` CLI cannot (its random pools exclude them); render them
  # through the pinned oracle's own renderer with the oracle's fixture
  # module (scripts/oracle-external-input.mjs).
  if (external_source = EXTERNAL_INPUT_SOURCES[effect_id])
    cmd = ["node", File.expand_path("oracle-external-input.mjs", __dir__), effect_id, out,
           "--width", size.to_s, "--height", size.to_s, "--seed", seed.to_s, "--time", render_time.to_s]
    _stdout, stderr, status = Open3.capture3(*cmd, stdin_data: external_source)
    raise "oracle failed: #{stderr}" unless status.success?

    return NoisemakerCpu::PNG.decode_png(File.binread(out))
  end
  program = NoisemakerOracle.particle_program(NoisemakerCpu::Renderer.meta["effects"].fetch(effect_id), params)
  cmd = ["node", cli, "effect", effect_id,
         "--width", size.to_s, "--height", size.to_s, "--seed", seed.to_s, "--time", render_time.to_s,
         "--output", out]
  cmd += ["--input", input_png] if input_png
  if program
    cmd[2, 2] = ["render", "-"]
  else
    params.each { |name, value| cmd += ["--param", "#{name}=#{value}"] }
  end
  _stdout, stderr, status = Open3.capture3(*cmd, chdir: cpu_dir, stdin_data: program || "")
  raise "oracle failed: #{stderr}" unless status.success?

  bytes =
    begin
      File.binread(out)
    rescue SystemCallError
      raise "oracle wrote nothing\n"
    end
  NoisemakerCpu::PNG.decode_png(bytes)
end

solid = lambda do |color = nil|
  NoisemakerCpu::Renderer.render_effect(
    "synth/solid", (color.nil? ? {} : { "color" => color }), nil,
    width: size, height: size, seed: seed, time: render_time
  )
end

ruby_render = lambda do |effect_id, kind, ext, render_params|
  eff = NoisemakerCpu::Renderer.meta["effects"].fetch(effect_id)
  if (external_source = EXTERNAL_INPUT_SOURCES[effect_id])
    return NoisemakerCpu::Renderer.render_dsl(
      external_source, width: size, height: size, seed: seed, time: render_time,
      external_inputs: REACTIVE_FIXTURES.fetch(effect_id)
    )
  end
  program = NoisemakerOracle.particle_program(eff, render_params)
  if program
    return NoisemakerCpu::Renderer.render_dsl(program, width: size, height: size, seed: seed, time: render_time)
  end
  domain = eff["domain"] || "image"
  unless domain == "image"
    args = render_params.map { |name, value| "#{name}: #{value}" }.join(", ")
    call = "#{eff['func']}(#{args})"
    source =
      if domain == "loop-begin" || domain == "loop-end"
        loop_begin = domain == "loop-begin" ? call : "loopBegin(iterationCount: 1)"
        loop_end = domain == "loop-end" ? call : "loopEnd()"
        "search render, synth\nsolid().#{loop_begin}.#{loop_end}.write(o0)\nrender(o0)"
      else
        supplied_size = render_params["volumeSize"]
        volume_size = supplied_size || eff.dig("params", "volumeSize", "default") || 16
        search = "search synth3d, filter3d, render"
        case domain
        when "volume-generator"
          "#{search}\n#{call}.render3d().write(o0)\nrender(o0)"
        when "volume-filter"
          "#{search}\nnoise3d(volumeSize: #{volume_size}).#{call}.render3d().write(o0)\nrender(o0)"
        else
          "#{search}\nnoise3d(volumeSize: #{volume_size}).#{call}.write(o0)\nrender(o0)"
        end
      end
    return NoisemakerCpu::Renderer.render_dsl(
      source, width: size, height: size, seed: seed, time: render_time
    )
  end
  if kind == "generator"
    inputs = ext ? { ext => ext_texture.call } : {}
    return NoisemakerCpu::Renderer.render_effect(effect_id, render_params, inputs,
                                                  width: size, height: size, seed: seed, time: render_time)
  end
  # Replicate the JS `effect` CLI: primary input is a default solid; each
  # surface param (mixers) gets solid(#f30 / #0cf), alternating by index.
  inputs = { "inputTex" => solid.call }
  inputs[ext] = ext_texture.call if ext
  params = eff["params"]
  order = (eff["paramOrder"] && !eff["paramOrder"].empty?) ? eff["paramOrder"] : params.keys.sort
  surf = order.select { |pn| params[pn].is_a?(Hash) && (params[pn]["type"] || "") == "surface" }
  surf.each_with_index do |pname, i|
    src = solid.call(i % 2 == 1 ? "#0cf" : "#f30")
    spec = params[pname]
    names = [spec["uniform"], spec["texture"], pname].compact.uniq
    names.each { |n| inputs[n] = src }
  end
  NoisemakerCpu::Renderer.render_effect(effect_id, render_params, inputs,
                                         width: size, height: size, seed: seed, time: render_time)
end

effects = NoisemakerCpu::Renderer.meta["effects"]
unknown_ids = only ? only.keys.reject { |eid| effects.key?(eid) }.sort : []
ids = effects.keys.sort.select { |eid| !only || only[eid] }

ok = []
diffs = []
errors = {}
oracle_err = []
exact = 0
ids.each do |eid|
  kind = effects[eid]["kind"]
  ext = effects[eid]["externalTexture"]
  render_params = {}
  if effects[eid]["iterated"]
    render_params["iterationCount"] = 1
    render_params["stateSize"] = 64 if effects[eid]["params"].key?("stateSize")
  end
  render_params["volumeSize"] = volume_size if effects[eid]["params"].key?("volumeSize")
  input_png = ext ? (ext_texture.call && ext_png) : nil
  js =
    begin
      js_effect.call(eid, File.join(tmp, "ph_js.png"), input_png, render_params)
    rescue StandardError => error
      warn "#{eid}: #{error.message}"
      nil
    end
  if js.nil?
    oracle_err << eid
    next
  end
  rb =
    begin
      ruby_render.call(eid, kind, ext, render_params)
    rescue StandardError => e
      key = (e.message.to_s.split("\n", 2).first || "")[0, 70]
      (errors[key] ||= []) << eid
      nil
    end
  next if rb.nil?

  ja = js.to_rgba8.unpack("C*")
  pa = rb.to_rgba8.unpack("C*")
  if ja.length != pa.length
    (errors["shape-mismatch"] ||= []) << eid
    next
  end
  d = 0
  ja.each_index do |i|
    x = (ja[i] - pa[i]).abs
    d = x if x > d
  end
  if d == 0
    ok << eid
    exact += 1
  else
    diffs << [eid, d]
  end
end

err_count = errors.values.sum(&:length)
printf("\n=== PARITY: %d/%d pass (byte-exact)  |  %d diff  |  %d runtime-error  |  %d oracle-error ===\n\n",
       ok.length, ids.length, diffs.length, err_count, oracle_err.length)
unless errors.empty?
  print "RUNTIME ERRORS (grouped):\n"
  errors.keys.sort_by { |msg| -errors[msg].length }.each do |msg|
    printf("  %3d  %s   e.g. %s\n", errors[msg].length, msg, errors[msg][0])
  end
end
unless diffs.empty?
  print "\nDIFFS (rendered but off):\n"
  sorted = diffs.sort_by { |d| -d[1] }
  take_n = diffs.length > 20 ? 20 : diffs.length
  sorted[0, take_n].each do |d|
    printf("  %4d  %s\n", d[1], d[0])
  end
end
unless oracle_err.empty?
  take_n = oracle_err.length > 5 ? 5 : oracle_err.length
  print "\nORACLE ERRORS (JS effect CLI failed): #{oracle_err.length}  e.g. #{oracle_err[0, take_n].join(" ")}\n"
end
print "\nUNKNOWN EFFECTS: #{unknown_ids.join(" ")}\n" unless unknown_ids.empty?
print "\nPASS: #{ok.length}  (byte-exact: #{exact})\n"

failed = ids.empty? || ok.length != ids.length || !diffs.empty? || !errors.empty? || !oracle_err.empty? || !unknown_ids.empty?
exit 1 if failed
