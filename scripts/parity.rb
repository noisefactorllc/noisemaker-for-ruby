#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

# Cross-language parity harness: render every bundled effect in Ruby vs the
# JS oracle (noisemaker-cpu `effect` CLI) at parity settings, and categorize.
#
# Usage: ruby scripts/parity.rb [--only id,id] [--size N]
#
# NOTE (integration dependency): this requires lib/noisemaker_cpu/{png,
# renderer,surface}.rb (Workers D/C/A) and a generated bundle
# (lib/noisemaker_cpu/bundle/, via scripts/build-bundle.rb --all, which
# itself needs Worker B's transpiler). It will only run at integration.

require "fileutils"
require "tmpdir"

require_relative "../lib/noisemaker_cpu/png"
require_relative "../lib/noisemaker_cpu/renderer"
require_relative "../lib/noisemaker_cpu/surface"

cpu_dir = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path(File.join(__dir__, "..", "..", "noisemaker-for-cpu"))
cli = File.join(cpu_dir, "bin", "noisemaker-cpu.js")

size = 8
seed = 1
render_time = 0.25
only = nil
ARGV.each_index do |i|
  only = ARGV[i + 1].split(",").each_with_object({}) { |x, h| h[x] = true } if ARGV[i] == "--only"
  size = ARGV[i + 1].to_i if ARGV[i] == "--size"
end

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
      d << x.fdiv(size - 1) << y.fdiv(size - 1) << ((x + y) % size).fdiv(size - 1) << 1.0
    end
  end
  surf = NoisemakerCpu::Surface.new(size, size, d)
  File.binwrite(ext_png, NoisemakerCpu::PNG.encode_png(surf))
  ext_tex = NoisemakerCpu::PNG.decode_png(File.binread(ext_png))
  ext_tex
end

js_effect = lambda do |effect_id, out, input_png, params|
  cmd = ["node", cli, "effect", effect_id,
         "--width", size.to_s, "--height", size.to_s, "--seed", seed.to_s, "--time", render_time.to_s,
         "--output", out]
  cmd += ["--input", input_png] if input_png
  params.each { |name, value| cmd += ["--param", "#{name}=#{value}"] }
  ok = system(*cmd, chdir: cpu_dir, out: File::NULL, err: File::NULL)
  raise "oracle failed\n" unless ok

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
  if kind == "generator"
    inputs = ext ? { ext => ext_texture.call } : {}
    return NoisemakerCpu::Renderer.render_effect(effect_id, render_params, inputs,
                                                  width: size, height: size, seed: seed, time: render_time)
  end
  # Replicate the JS `effect` CLI: primary input is a default solid; each
  # surface param (mixers) gets solid(#f30 / #0cf), alternating by index.
  inputs = { "inputTex" => solid.call }
  inputs[ext] = ext_texture.call if ext
  eff = NoisemakerCpu::Renderer.meta["effects"][effect_id]
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
  input_png = ext ? (ext_texture.call && ext_png) : nil
  js =
    begin
      js_effect.call(eid, File.join(tmp, "ph_js.png"), input_png, render_params)
    rescue StandardError
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
  if d <= 2
    ok << eid
    if d == 0
      exact += 1
    else
      print "NEARMISS #{d} #{eid}\n"
    end
  else
    diffs << [eid, d]
  end
end

err_count = errors.values.sum(&:length)
printf("\n=== PARITY: %d/%d pass (<=2)  |  %d diff  |  %d runtime-error  |  %d oracle-error ===\n\n",
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
