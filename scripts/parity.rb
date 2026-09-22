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
