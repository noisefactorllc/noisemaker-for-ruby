#!/usr/bin/env ruby
# frozen_string_literal: true

# Extended qualification sweep on top of scripts/parity.rb's default gate.
#
# For every bundled effect this renders a case grid against the pinned
# JavaScript oracle (noisemaker-cpu) and writes a raw machine-readable report:
#
#   - default case          (identical settings to scripts/parity.rb)
#   - nondefault parameters (up to 3 scalar params moved off their defaults)
#   - animation             (time 0.0 and 1.0, plus the default time 0.25)
#   - iterated state        (iterationCount 3 for iterated effects)
#   - alternative seed      (seed 7)
#   - larger scene          (16x16)
#   - volume size variation (volumeSize 8 for volume effects)
#
# Every case, parameter choice, exclusion, error and tolerance is reported.
# Tolerance is byte-exact RGBA8 (maxdiff 0); nothing is tolerated.
#
# Usage:
#   ruby scripts/parity-sweep.rb [--report PATH] [--only id,id]
#                                [--no-case NAME,...] [--all-params] [--jobs N]
#
# --all-params drops the 3-parameter cap and renders a nondefault case for
# every parameter with a deterministic nondefault value (opt-in; the default
# grid stays capped so whole-port sweeps stay bounded).
#
require "digest"
require "fileutils"
require "tmpdir"
require "optparse"
require_relative "oracle"
require_relative "reactive_fixtures"

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

report_path = nil
only = nil
skip_cases = {}
shard = nil
merge_files = nil
all_params = false
raw_command = "ruby #{$PROGRAM_NAME} #{ARGV.join(' ')}".strip
OptionParser.new do |opts|
  opts.on("--report PATH") { |value| report_path = value }
  opts.on("--only IDS") { |value| only = value.split(",").to_h { |id| [id, true] } }
  opts.on("--skip-case NAMES", String) { |value| skip_cases = value.split(",").to_h { |c| [c, true] } }
  opts.on("--all-params") { all_params = true }
  opts.on("--shard I/M") { |value| shard = value.split("/").map { |p| Integer(p, 10) } }
  opts.on("--merge FILES", String) { |value| merge_files = value.split(",") }
end.parse!
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "--shard expects I/M with 0 <= I < M" if shard && !(shard.length == 2 && (0...shard[1]).cover?(shard[0]))

def sha256_file(path)
  Digest::SHA256.file(path).hexdigest
rescue StandardError
  nil
end

def tree_manifest(root, prefixes)
  out = {}
  Dir.glob(prefixes.map { |p| File.join(root, p) }, File::FNM_DOTMATCH).sort.each do |abs|
    next unless File.file?(abs)
    rel = abs.delete_prefix("#{root}/")
    next if rel.start_with?(".git/")
    out[rel] = Digest::SHA256.file(abs).hexdigest
  end
  out
end

tmp = Dir.mktmpdir
at_exit { FileUtils.remove_entry(tmp) }
ext_png = File.join(tmp, "ph_ext.png")

# Per-case working images so each PNG digest binds exactly one case.
js_png_path = lambda do |key|
  File.join(tmp, "js-#{key}.png")
end

ext_tex_cache = {}
ext_texture = lambda do |size|
  ext_tex_cache[size] ||= begin
    d = []
    (0...size).each do |y|
      (0...size).each do |x|
        d << x.fdiv([size - 1, 1].max) << y.fdiv([size - 1, 1].max) << ((x + y) % size).fdiv([size - 1, 1].max) << 1.0
      end
    end
    surf = NoisemakerCpu::Surface.new(size, size, d)
    png = File.join(tmp, "ph_ext-#{size}.png")
    File.binwrite(png, NoisemakerCpu::PNG.encode_png(surf))
    [NoisemakerCpu::PNG.decode_png(File.binread(png)), png]
  end
end

js_effect = lambda do |effect_id, out, input_png, params, js_params, size, seed, render_time|
  raise oracle_error if oracle_error
  # The reactive/mesh cases bind deterministic external-input fixtures, which
  # the `effect` CLI cannot (its random pools exclude them); render them
  # through the pinned oracle's own renderer with the oracle's fixture
  # module (scripts/oracle-external-input.mjs), with the case's parameters
  # injected into the DSL program.
  if (external_source = EXTERNAL_INPUT_SOURCES[effect_id])
    cmd = ["node", File.expand_path("oracle-external-input.mjs", __dir__), effect_id, out,
           "--width", size.to_s, "--height", size.to_s, "--seed", seed.to_s, "--time", render_time.to_s]
    _stdout, stderr, status = Open3.capture3(*cmd, stdin_data: external_input_source_for(effect_id, params))
  else
    program = NoisemakerOracle.particle_program(NoisemakerCpu::Renderer.meta["effects"].fetch(effect_id), params)
    cmd = ["node", cli, "effect", effect_id,
           "--width", size.to_s, "--height", size.to_s, "--seed", seed.to_s, "--time", render_time.to_s,
           "--output", out]
    cmd += ["--input", input_png] if input_png
    if program
      cmd[2, 2] = ["render", "-"]
    else
      js_params.each { |name, value| cmd += ["--param", "#{name}=#{value}"] }
    end
    _stdout, stderr, status = Open3.capture3(*cmd, chdir: cpu_dir, stdin_data: program || "")
  end
  raise "oracle failed: #{stderr}" unless status.success?

  bytes =
    begin
      File.binread(out)
    rescue SystemCallError
      raise "oracle wrote nothing\n"
    end
  [NoisemakerCpu::PNG.decode_png(bytes), Digest::SHA256.hexdigest(bytes)]
end

solid = lambda do |color, size, seed, render_time|
  NoisemakerCpu::Renderer.render_effect(
    "synth/solid", (color.nil? ? {} : { "color" => color }), nil,
    width: size, height: size, seed: seed, time: render_time
  )
end

ruby_render = lambda do |effect_id, kind, ext, render_params, size, seed, render_time, volume_size|
  eff = NoisemakerCpu::Renderer.meta["effects"].fetch(effect_id)
  # The reactive/mesh cases bind the same deterministic external-input
  # fixtures as the default gate (scripts/reactive_fixtures.rb), with the
  # case's parameters injected into the DSL program.
  if (external_source = EXTERNAL_INPUT_SOURCES[effect_id])
    return NoisemakerCpu::Renderer.render_dsl(
      external_input_source_for(effect_id, render_params),
      width: size, height: size, seed: seed, time: render_time,
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
        vsize = supplied_size || eff.dig("params", "volumeSize", "default") || 16
        search = "search synth3d, filter3d, render"
        case domain
        when "volume-generator"
          "#{search}\n#{call}.render3d().write(o0)\nrender(o0)"
        when "volume-filter"
          "#{search}\nnoise3d(volumeSize: #{vsize}).#{call}.render3d().write(o0)\nrender(o0)"
        else
          "#{search}\nnoise3d(volumeSize: #{vsize}).#{call}.write(o0)\nrender(o0)"
        end
      end
    return NoisemakerCpu::Renderer.render_dsl(
      source, width: size, height: size, seed: seed, time: render_time
    )
  end
  if kind == "generator"
    inputs = ext ? { ext => ext_texture.call(size)[0] } : {}
    return NoisemakerCpu::Renderer.render_effect(effect_id, render_params, inputs,
                                                 width: size, height: size, seed: seed, time: render_time)
  end
  inputs = { "inputTex" => solid.call(nil, size, seed, render_time) }
  inputs[ext] = ext_texture.call(size)[0] if ext
  params = eff["params"]
  order = (eff["paramOrder"] && !eff["paramOrder"].empty?) ? eff["paramOrder"] : params.keys.sort
  surf = order.select { |pn| params[pn].is_a?(Hash) && (params[pn]["type"] || "") == "surface" }
  surf.each_with_index do |pname, i|
    src = solid.call(i % 2 == 1 ? "#0cf" : "#f30", size, seed, render_time)
    spec = params[pname]
    names = [spec["uniform"], spec["texture"], pname].compact.uniq
    names.each { |n| inputs[n] = src }
  end
  NoisemakerCpu::Renderer.render_effect(effect_id, render_params, inputs,
                                        width: size, height: size, seed: seed, time: render_time)
end

# ---- case grid ------------------------------------------------------------

def nondefault_value(spec)
  case spec["type"]
  when "float", "int", "palette"
    choices = spec["choices"].is_a?(Hash) ? spec["choices"] : nil
    if choices
      alt = choices.reject { |_, v| v == spec["default"] }.first
      return nil if alt.nil?
      return alt[1]
    end
    return nil unless spec.key?("min") && spec.key?("max") && spec.key?("default")
    min = spec["min"].to_f
    max = spec["max"].to_f
    return nil if max <= min
    pick = spec["default"].to_f <= (min + max) / 2 ? spec["max"] : spec["min"]
    spec["type"] == "float" ? pick.to_f : pick.to_i
  when "bool", "boolean"
    return nil if spec["default"].nil?
    !spec["default"]
  when "member"
    # Swap one shared-enum member for another (e.g. channel.r -> channel.g).
    key = spec["default"].to_s.split(".")
    return nil unless key.length == 2
    base = key[0]
    alt = { "r" => "g", "g" => "b", "b" => "r", "x" => "y", "y" => "z", "z" => "x" }[key[1]]
    return nil if alt.nil?
    "#{base}.#{alt}"
  when "string"
    choices = spec["choices"].is_a?(Hash) ? spec["choices"] : nil
    if choices
      alt = choices.reject { |_, v| v == spec["default"] }.first
      return nil if alt.nil?
      return alt[1]
    end
    return nil if spec["default"] == "Parity Sweep"
    "Parity Sweep"
  when "vec2", "vec3", "vec4"
    n = spec["type"][-1].to_i
    return Array.new(n) { |i| 0.25 + 0.25 * i } if spec["default"] != Array.new(n) { |i| 0.25 + 0.25 * i }
    Array.new(n, 0.75)
  when "mat3"
    [0, 1, 0, 1, 0, 0, 0, 0, 1]
  when "color"
    "#3a7bff"
  end
end

# JS CLI --param wants a single token per value; arrays go as DSL literals.
def js_param_string(value)
  if value.is_a?(Array)
    "[#{value.join(',')}]"
  else
    value.to_s
  end
end

def renderable_value(value)
  value
end

effects = NoisemakerCpu::Renderer.meta["effects"]
unknown_ids = only ? only.keys.reject { |eid| effects.key?(eid) }.sort : []
all_ids = effects.keys.sort.select { |eid| !only || only[eid] }
ids = shard ? all_ids.each_with_index.select { |_, i| i % shard[1] == shard[0] }.map(&:first) : all_ids

def case_grid(eff, skip_cases, all_params = false)
  eid = eff.fetch("id")
  params = eff["params"] || {}
  order = (eff["paramOrder"] && !eff["paramOrder"].empty?) ? eff["paramOrder"] : params.keys.sort
  cases = []
  exclusions = []
  cases << { "name" => "default", "params" => {}, "time" => 0.25, "seed" => 1, "size" => 8, "volumeSize" => 16 }
  # Nondefault parameters: up to 3 scalar params moved off their defaults.
  param_cases = []
  order.each do |pname|
    spec = params[pname]
    next unless spec.is_a?(Hash)
    next if pname == "volumeSize"
    value = nondefault_value(spec)
    if value.nil?
      exclusions << { "param" => pname, "type" => spec["type"],
                      "reason" => %w[surface volume geometry].include?(spec["type"]) ? "bound via inputs" : "no deterministic nondefault value derivable from metadata" }
      next
    end
    next if value == spec["default"]
    if !all_params && param_cases.length >= 3
      exclusions << { "param" => pname, "type" => spec["type"],
                      "reason" => "capped: at most 3 nondefault-parameter cases per effect" }
      next
    end
    param_cases << { "name" => "param-#{pname}", "params" => { pname => renderable_value(value) },
                     "time" => 0.25, "seed" => 1, "size" => 8, "volumeSize" => 16,
                     "param" => pname, "value" => value }
  end
  cases.concat(param_cases)
  # Animation: time 0.0 and 1.0 (default case already carries 0.25).
  cases << { "name" => "time-0", "params" => {}, "time" => 0.0, "seed" => 1, "size" => 8, "volumeSize" => 16 }
  cases << { "name" => "time-1", "params" => {}, "time" => 1.0, "seed" => 1, "size" => 8, "volumeSize" => 16 }
  # Iterated state: three iterations instead of one.
  if eff["iterated"]
    iter3 = { "iterationCount" => 3 }
    iter3["stateSize"] = 64 if params.key?("stateSize")
    cases << { "name" => "iter-3", "params" => iter3,
               "time" => 0.25, "seed" => 1, "size" => 8, "volumeSize" => 16 }
  end
  # Alternative seed.
  cases << { "name" => "seed-7", "params" => {}, "time" => 0.25, "seed" => 7, "size" => 8, "volumeSize" => 16 }
  # Larger scene.
  cases << { "name" => "size-16", "params" => {}, "time" => 0.25, "seed" => 1, "size" => 16, "volumeSize" => 16 }
  # Volume size variation for volume effects.
  cases << { "name" => "volume-8", "params" => {}, "time" => 0.25, "seed" => 1, "size" => 8, "volumeSize" => 8 } if params.key?("volumeSize")
  [cases.reject { |c| skip_cases[c["name"]] }, exclusions]
end

# ---- run ------------------------------------------------------------------

started = Time.now
report = {
  "schema" => "noisemaker-for-ruby/parity-sweep/1",
  "shard" => shard ? "#{shard[0]}/#{shard[1]}" : nil,
  "shard_effects" => shard ? ids.length : nil,
  "total_effects" => all_ids.length,
  "started" => started.utc.iso8601,
  "command" => raw_command,
  "ruby" => RUBY_DESCRIPTION,
  "node" => `node --version 2>/dev/null`.strip,
  "host" => `uname -smr 2>/dev/null`.strip,
  "tolerance" => "byte-exact RGBA8 (maxdiff 0); no tolerated differences",
  "candidate" => {
    "git_head" => `git -C #{File.expand_path('..', __dir__)} rev-parse HEAD 2>/dev/null`.strip,
    "git_dirty" => nil,
    "source_hashes" => nil
  },
  "oracle" => {
    "lock" => JSON.parse(File.read(File.join(__dir__, "oracle-lock.json"))),
    "git_head" => `git -C #{cpu_dir} rev-parse HEAD 2>/dev/null`.strip,
    "git_dirty" => nil,
    "source_hashes" => nil
  },
  "cases" => [],
  "summary" => nil
}

root = File.expand_path("..", __dir__)
report["candidate"]["git_dirty"] = system("git", "-C", root, "diff", "--quiet", "HEAD", "--") ? false : true
report["oracle"]["git_dirty"] = system("git", "-C", cpu_dir, "diff", "--quiet", "HEAD", "--") ? false : true
report["candidate"]["source_hashes"] = tree_manifest(root, ["lib/**/*", "scripts/**/*", "test/**/*", "*.gemspec", "Gemfile", "Gemfile.lock", "Rakefile", "exe/**/*"])
report["oracle"]["source_hashes"] = tree_manifest(cpu_dir, ["**/*"])

if merge_files
  raise "--report PATH is required with --merge" unless report_path
  uniq = {}
  exclusions = []
  runs = []
  merge_files.each do |f|
    src = JSON.parse(File.read(f))
    raise "schema mismatch in #{f}" unless src.is_a?(Hash) && src["schema"] == report["schema"]
    raise "incomplete run #{f}" if src["ended"].nil? || (src["cases"] || []).empty?
    (src["exclusions"] || []).each { |x| exclusions << x }
    (src["cases"] || []).each { |c| uniq[[c["effect"], c["case"]]] = c }
    runs << {
      "report" => File.expand_path(f),
      "shard" => src["shard"],
      "command" => src["command"],
      "ruby" => src["ruby"],
      "started" => src["started"],
      "ended" => src["ended"],
      "candidate" => src["candidate"].slice("git_head", "git_dirty"),
      "oracle" => src["oracle"].slice("git_head", "git_dirty"),
      "effects" => (src["cases"] || []).map { |c| c["effect"] }.uniq.sort
    }
  end
  counts = Hash.new(0)
  uniq.each_value { |c| counts[c["status"]] += 1 }
  # Case-level completeness: every covered effect must have its full grid.
  uniq.values.map { |c| c["effect"] }.uniq.each do |eid|
    raise "unknown effect #{eid}" unless effects.key?(eid)
    eff = effects[eid].merge("id" => eid)
    want = case_grid(eff, skip_cases, all_params)[0].map { |c| c["name"] }
    got = uniq.select { |(e, _), _| e == eid }.keys.map { |(_, n)| n }
    missing_cases = want - got
    raise "incomplete grid for #{eid}: missing #{missing_cases.join(',')}" unless missing_cases.empty?
  end
  oracle_heads = runs.map { |r| r.dig("oracle", "git_head") }.uniq
  raise "oracle heads differ across runs: #{oracle_heads.join(',')}" if oracle_heads.length != 1
  report["oracle"]["git_head"] = oracle_heads.first
  report["oracle"]["git_dirty"] = runs.all? { |r| r.dig("oracle", "git_dirty") == false } ? false : true
  report["oracle"]["source_hashes"] = runs.first.dig("oracle", "source_hashes")
  missing = all_ids - uniq.values.map { |c| c["effect"] }.uniq
  report["shard"] = "merged"
  report["shard_effects"] = uniq.values.map { |c| c["effect"] }.uniq.length
  report["runs"] = runs
  report["exclusions"] = exclusions.uniq.sort_by { |x| [x["effect"], x["param"]] }
  report["cases"] = uniq.values.sort_by { |c| [c["effect"], c["case"]] }
  report["summary"] = {
    "effects" => uniq.values.map { |c| c["effect"] }.uniq.length,
    "cases" => counts.values.sum,
    "by_status" => counts.transform_keys(&:to_s),
    "effect_denominator" => all_ids.length,
    "case_denominator" => counts.values.sum,
    "all_exact" => counts.values.sum == counts["exact"],
    "missing_effects" => missing
  }
  report["ended"] = Time.now.utc.iso8601
  File.write(report_path, JSON.pretty_generate(report))
  printf("\n=== PARITY-SWEEP (merged): %d/%d cases byte-exact | %d effects of %d | %d missing effects ===\n",
         counts["exact"], counts.values.sum, report["shard_effects"], all_ids.length, missing.length)
  print "REPORT: #{report_path}\n"
  exit(missing.empty? && counts["exact"] == counts.values.sum ? 0 : 1)
end

counts = Hash.new(0)
case_failures = []
ids.each do |eid|
  eff = effects[eid].dup
  eff["id"] = eid
  kind = effects[eid]["kind"]
  ext = effects[eid]["externalTexture"]
  grid, exclusions = case_grid(eff, skip_cases, all_params)
  report["exclusions"] ||= []
  report["exclusions"].concat(exclusions.map { |x| x.merge("effect" => eid) })
  grid.each do |cs|
    size = cs["size"]
    seed = cs["seed"]
    render_time = cs["time"]
    volume_size = cs["volumeSize"]
    render_params = {}
    if effects[eid]["iterated"] && cs["params"]["iterationCount"].nil?
      render_params["iterationCount"] = 1
      render_params["stateSize"] = 64 if effects[eid]["params"].key?("stateSize")
    end
    render_params.merge!(cs["params"])
    render_params["volumeSize"] = volume_size if effects[eid]["params"].key?("volumeSize")
    ext_tex_pair = ext ? ext_texture.call(size) : nil
    input_png = ext ? ext_tex_pair[1] : nil
    out_png = js_png_path.call("#{eid.tr('/', '_')}-#{cs['name']}")
    row = {
      "effect" => eid,
      "case" => cs["name"],
      "params" => render_params.reject { |k, _| k == "volumeSize" },
      "volumeSize" => render_params["volumeSize"],
      "time" => render_time,
      "seed" => seed,
      "size" => size
    }
    row["externalTexture"] = true if ext
    js =
      begin
        js_effect.call(eid, out_png, input_png, render_params,
                       render_params.transform_values { |v| js_param_string(v) },
                       size, seed, render_time)
      rescue StandardError => error
        row["status"] = "oracle-error"
        row["error"] = error.message.to_s[0, 400]
        report["cases"] << row
        counts["oracle-error"] += 1
        case_failures << row
        print "ORACLE-ERROR #{eid} #{cs['name']}: #{row['error']}\n"
        next
      end
    rb =
      begin
        ruby_render.call(eid, kind, ext, render_params, size, seed, render_time, volume_size)
      rescue StandardError => e
        row["status"] = "ruby-error"
        row["error"] = e.message.to_s[0, 400]
        report["cases"] << row
        counts["ruby-error"] += 1
        case_failures << row
        print "RUBY-ERROR #{eid} #{cs['name']}: #{row['error']}\n"
        next
      end
    ja = js[0].to_rgba8.unpack("C*")
    pa = rb.to_rgba8.unpack("C*")
    row["oracle_png_sha256"] = js[1]
    if ja.length != pa.length
      row["status"] = "shape-mismatch"
      row["error"] = "byte length #{ja.length} vs #{pa.length}"
      report["cases"] << row
      counts["shape-mismatch"] += 1
      case_failures << row
      print "SHAPE-MISMATCH #{eid} #{cs['name']}\n"
      next
    end
    d = 0
    ja.each_index do |i|
      x = (ja[i] - pa[i]).abs
      d = x if x > d
    end
    row["maxdiff"] = d
    row["ruby_png_sha256"] = Digest::SHA256.hexdigest(NoisemakerCpu::PNG.encode_png(rb))
    if d.zero?
      row["status"] = "exact"
      counts["exact"] += 1
    else
      row["status"] = "diff"
      case_failures << row
      counts["diff"] += 1
      print "DIFF #{eid} #{cs['name']} maxdiff #{d}\n"
    end
    report["cases"] << row
  end
  if report_path
    File.write(report_path, JSON.pretty_generate(report))
  end
end

report["summary"] = {
  "effects" => ids.length,
  "cases" => counts.values.sum,
  "by_status" => counts.transform_keys(&:to_s),
  "effect_denominator" => ids.length,
  "case_denominator" => counts.values.sum,
  "all_exact" => counts.values.sum == counts["exact"]
}
report["ended"] = Time.now.utc.iso8601

total = counts.values.sum
printf("\n=== PARITY-SWEEP: %d/%d cases byte-exact | %d diff | %d ruby-error | %d oracle-error | %d shape-mismatch ===\n",
       counts["exact"], total, counts["diff"], counts["ruby-error"], counts["oracle-error"], counts["shape-mismatch"])
unless case_failures.empty?
  print "\nNON-EXACT CASES:\n"
  case_failures.each do |row|
    print "  #{row['effect']} #{row['case']} #{row['status']}"
    print " maxdiff #{row['maxdiff']}" if row["maxdiff"]
    print " :: #{row['error']}" if row["error"]
    print "\n"
  end
end
print "\nUNKNOWN EFFECTS: #{unknown_ids.join(' ')}\n" unless unknown_ids.empty?

if report_path
  File.write(report_path, JSON.pretty_generate(report))
  print "\nREPORT: #{report_path}\n"
end

failed = ids.empty? || total.zero? || counts["exact"] != total || !unknown_ids.empty?
exit 1 if failed
