#!/usr/bin/env ruby
# frozen_string_literal: true

# PARITY-SUMMARY contract entrypoint.
#
# Renders the current authority's manifest cases with this port and compares
# each against the authority's golden (rendered by the pinned noisemaker-cpu
# oracle checkout, located via NOISEMAKER_CPU_DIR like scripts/parity.rb).
# Given case ids as arguments, it renders and counts only those; with no
# arguments it covers the whole port (every id in the current authority's
# manifest).
#
# The last output line is:
#   PARITY-SUMMARY {"expected":N,"executed":N,"exact":N,"strict":N,"near":N,"defer":N,"skip":N,"fail":N,"missing":N}
#
# Before it, every requested case is reported once with a verdict line, the
# same shapes the CPU port's summary prints (auditable by scripts/release-gate.rb):
#   EXACT/FAIL/DEFER/MISSING <id> (<reason>)
#
#   expected  the authority's cases (the full authority manifest ids, or the
#             requested subset of them)
#   executed  cases actually rendered by both engines
#   exact     byte-identical RGBA8
#   strict    other passes within the port's published numerical contract
#   near      tolerated mismatches beyond that contract
#   defer     cases not evaluated (oracle unavailable/failed)
#   skip      cases skipped by design
#   fail      rendered but mismatching, or a port runtime error
#   missing   expected cases not executed
#
# Exit 0 iff expected > 0, executed == expected, exact + strict == expected,
# and near, defer, skip, fail and missing are all zero.
#
# The authority case set is the current authority's full manifest (the
# upstream manifest recorded by the pinned oracle's upstream snapshot), not
# the port bundle: ids the pinned oracle does not implement have no golden
# and cannot be executed, so they are counted as missing and the whole-port
# run exits 1 while any authority id lacks an oracle-side implementation.
# Given explicit case ids, ids outside the authority manifest are rejected
# as unknown.
#
# The port's published numerical contract is byte-exact RGBA8 (maxdiff 0),
# so every pass is exact and strict is always 0.

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# The authority golden is rendered by the pinned noisemaker-cpu oracle
# (scripts/oracle-lock.json). When NOISEMAKER_CPU_DIR does not already point
# at a usable pinned checkout, provision one on demand into a cache outside
# the repository (same discipline as the Ruby toolchain in ruby-bootstrap.sh)
# so the entrypoint is self-sufficient in a bare check container.
def provision_oracle
  lock = JSON.parse(File.read(File.expand_path("oracle-lock.json", __dir__)))
  revision = lock.fetch("revision")
  dir = ENV["NOISEMAKER_CPU_DIR"]
  return dir if dir && File.file?(File.join(dir, "bin", "noisemaker-cpu.js"))
  return nil if system("git", "-C", File.expand_path("../..", __dir__),
                       "rev-parse", "-q", "--verify", "#{revision}^{commit}",
                       out: File::NULL, err: File::NULL) &&
               File.file?(File.expand_path("../../noisemaker-for-cpu/bin/noisemaker-cpu.js", __dir__))

  base = ENV["NOISEMAKER_PARITY_CACHE"]
  base ||= ["/tmp/noisemaker-parity-cache", File.join(Dir.home.to_s, ".cache", "noisemaker-parity")]
          .find { |c| c.start_with?("/tmp/", "#{Dir.home}/") && (File.directory?(c) || FileUtils.mkdir_p(c) rescue false) }
  return nil unless base

  dir = File.join(base, "noisemaker-for-cpu")
  url = lock.fetch("repository")
  unless File.directory?(File.join(dir, ".git"))
    warn "scripts/parity-summary: provisioning the pinned oracle #{revision[0, 12]} from #{url}"
    # Shallow single-revision fetch: the gate only renders this pinned commit,
    # so bounded wall time must not pay for the repository's full history.
    ok = system("git", "init", "--quiet", dir, out: File::NULL, err: File::NULL) &&
         system("git", "-C", dir, "fetch", "--quiet", "--depth", "1", url, revision,
                out: File::NULL, err: File::NULL)
    unless ok
      FileUtils.rm_rf(dir)
      return nil unless system("git", "clone", "--quiet", "--filter=blob:none", url, dir,
                               out: File::NULL, err: File::NULL)
    end
  end
  have = system("git", "-C", dir, "cat-file", "-e", "#{revision}^{commit}",
                out: File::NULL, err: File::NULL)
  unless have
    return nil unless system("git", "-C", dir, "fetch", "--quiet", "--depth", "1", url, revision,
                             out: File::NULL, err: File::NULL)
  end
  return nil unless system("git", "-C", dir, "checkout", "--quiet", "--detach", revision,
                           out: File::NULL, err: File::NULL)
  warn "scripts/parity-summary: using provisioned oracle at #{dir}"
  dir
end

if (provisioned = provision_oracle)
  ENV["NOISEMAKER_CPU_DIR"] = provisioned
end

require_relative "oracle"
require_relative "../lib/noisemaker_cpu/renderer"

manifest_ids = NoisemakerCpu::Renderer.meta["effects"].keys.sort

# The authority case set is the current authority's full manifest, recorded
# by the pinned oracle's upstream snapshot (currently 210 ids). The port
# bundle is a subset of it: ids the pinned oracle does not implement have
# no golden and cannot be executed, so they count as missing rather than
# shrinking the denominator to the bundle.
oracle_dir = ENV["NOISEMAKER_CPU_DIR"]
snapshot_path = oracle_dir && File.join(oracle_dir, "src", "effects", "generated", "upstream-snapshot.js")
abort "parity-summary: no pinned oracle checkout; cannot read the authority manifest" unless oracle_dir && File.file?(snapshot_path)
node_out, node_err, node_status = Open3.capture3(
  "node", "-e",
  "const m = require(process.argv[1]); console.log(JSON.stringify((m.default || m).sourceEffectIds))",
  snapshot_path
)
abort "parity-summary: cannot read the authority manifest from the pinned oracle:\n#{node_err}" unless node_status.success?
authority_ids = JSON.parse(node_out).sort

args = ARGV.reject { |a| a.start_with?("--") }
unknown = args.uniq - authority_ids
unless unknown.empty?
  warn "unknown case ids: #{unknown.join(' ')}"
  warn "PARITY-SUMMARY #{JSON.generate(expected: args.uniq.length, executed: 0, exact: 0, strict: 0, near: 0, defer: 0, skip: 0, fail: 0, missing: args.uniq.length)}"
  exit 1
end

ids = args.empty? ? authority_ids : args.uniq.sort
executable_ids = ids & manifest_ids
not_bundled = ids - manifest_ids
unless not_bundled.empty?
  warn "not in the port bundle (no executable case); counted missing: #{not_bundled.join(' ')}"
end

def run_gate(ids)
  out, _err, status = Open3.capture3(
    RbConfig.ruby, "--yjit", File.expand_path("parity.rb", __dir__), "--only", ids.join(",")
  )
  [out, status.success?]
end

verdicts = {}
if args.empty? && executable_ids.length > 1 &&
   (shard_n = (ENV["NM_EFF_CORES"]&.to_i || Etc.nprocessors) + 2) > 1
  # Bounded wall time: the whole-port run is a single test invocation, so it
  # executes as concurrent workers that each claim the next dynamic batch of
  # case ids and run this same entrypoint on it (the child takes the serial
  # path for one batch). Dynamic batches keep the wall near total_work divided
  # by workers instead of letting a slow static shard gate the whole run.
  # Every case is still rendered and compared; per-case verdicts and summary
  # counts are merged here into the same contract output.
  batch_n = 30
  next_batch = 0
  merge = Mutex.new
  totals = Hash.new(0)
  shard_err = nil
  workers = Array.new(shard_n) do
    Thread.new do
      loop do
        group = merge.synchronize do
          # Measured costs (bounded per-case probe): these cases each render in
          # 90s or more, so each gets its own batch instead of sharing one with
          # fast cases; coverage is unchanged, only the claim size differs.
          slow_one = /\A(?:filter3d\/flow3d|render\/render(?:3d|Lit3d|Landscape3d|Cubemap3d|CubemapSurface)|points\/life)\z/.match?(executable_ids[next_batch].to_s)
          group = executable_ids[next_batch, slow_one ? 1 : batch_n]
          next_batch += slow_one ? 1 : batch_n
          group
        end
        break if group.nil? || group.empty?
        begin
          out, _err, status = Open3.capture3(
            RbConfig.ruby, "--yjit", File.expand_path("parity-summary.rb", __dir__), *group
          )
          summary = out[/^PARITY-SUMMARY (\{.*\})$/, 1]
          raise "parity batch exited #{status.exitstatus} without PARITY-SUMMARY:\n#{out}" unless summary && status.success?
          merge.synchronize do
            JSON.parse(summary).each { |key, value| totals[key] += value.to_i }
            out.each_line do |entry|
              next unless entry =~ /\A(EXACT|STRICT|FAIL|SKIP|MISSING|NEAR|DEFER) (\S+)/
              verdicts[Regexp.last_match(2)] = Regexp.last_match(1)
            end
          end
        rescue => shard_error
          merge.synchronize { shard_err ||= shard_error.message }
          break
        end
      end
    end
  end
  workers.each(&:join)
  abort "parity-summary: parity worker failed:\n#{shard_err}" if shard_err
  exact = totals["exact"]
  fail_count = totals["fail"]
  defer_count = totals["defer"]
else
  out, =
    if executable_ids.empty?
      ["", true]
    else
      run_gate(executable_ids)
    end
  line = out[/^=== PARITY: (\d+)\/(\d+) pass \(byte-exact\)  \|  (\d+) diff  \|  (\d+) runtime-error  \|  (\d+) oracle-error ===$/, 0]
  abort "parity-summary: could not parse scripts/parity.rb output\n#{out}" unless line

  m = line.match(/^=== PARITY: (\d+)\/(\d+) pass \(byte-exact\)  \|  (\d+) diff  \|  (\d+) runtime-error  \|  (\d+) oracle-error ===$/)
  passed, _requested, diff_count, error_count, oracle_count = m.captures.map(&:to_i)

  if diff_count.zero? && error_count.zero? && oracle_count.zero?
  exact = passed
  fail_count = 0
  defer_count = 0
  executable_ids.each { |cid| verdicts[cid] = "EXACT" }
else
  # Classify per case so counts stay exact instead of inferring from groups.
  exact = 0
  fail_count = 0
  defer_count = 0
  executable_ids.each do |cid|
    out1, ok1 = run_gate([cid])
    if out1.include?("ORACLE ERRORS")
      defer_count += 1
      verdicts[cid] = "DEFER"
    elsif ok1
      exact += 1
      verdicts[cid] = "EXACT"
    else
      fail_count += 1
      verdicts[cid] = "FAIL"
    end
  end
end
end

# Per-case verdict lines, the same shapes the CPU port's summary prints so a
# release gate can audit every reported id (scripts/release-gate.rb). SKIP
# never occurs here: the port has no skip policy, every bundle case renders.
not_bundled.each { |cid| verdicts[cid] = "MISSING" }
reasons = {
  "EXACT" => "byte-exact vs the pinned oracle",
  "FAIL" => "rendered but mismatching, or a port runtime error",
  "DEFER" => "oracle unavailable or failed",
  "MISSING" => "not in the port bundle"
}
verdicts.sort.each do |cid, verdict|
  puts "#{verdict} #{cid} (#{reasons.fetch(verdict)})"
end

expected = ids.length
missing = expected - exact - fail_count - defer_count
missing = 0 if missing.negative?
counts = {
  expected: expected, executed: exact + fail_count,
  exact: exact, strict: 0, near: 0, defer: defer_count,
  skip: 0, fail: fail_count, missing: missing
}
puts "PARITY-SUMMARY #{JSON.generate(counts)}"

pass = counts[:expected].positive? &&
       counts[:executed] == counts[:expected] &&
       counts[:exact] + counts[:strict] == counts[:expected] &&
       counts[:near].zero? && counts[:defer].zero? && counts[:skip].zero? &&
       counts[:fail].zero? && counts[:missing].zero?
exit(pass ? 0 : 1)
