#!/usr/bin/env ruby
# frozen_string_literal: true

# PARITY-SUMMARY contract entrypoint.
#
# Renders the current authority's manifest cases with this port and compares
# each against the authority's golden (rendered by the pinned noisemaker-cpu
# oracle checkout, located via NOISEMAKER_CPU_DIR like scripts/parity.rb).
# Given case ids as arguments, it renders and counts only those; with no
# arguments it covers the whole port (every manifest effect).
#
# The last output line is:
#   PARITY-SUMMARY {"expected":N,"executed":N,"exact":N,"strict":N,"near":N,"defer":N,"skip":N,"fail":N,"missing":N}
#
#   expected  the authority's cases (manifest ids, or the requested subset)
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
          .find { |c| c.start_with?("/tmp/", "/state/", "#{Dir.home}/") && (File.directory?(c) || FileUtils.mkdir_p(c) rescue false) }
  return nil unless base

  dir = File.join(base, "noisemaker-for-cpu")
  unless File.directory?(File.join(dir, ".git"))
    url = lock.fetch("repository")
    warn "scripts/parity-summary: provisioning the pinned oracle #{revision[0, 12]} from #{url}"
    return nil unless system("git", "clone", "--quiet", "--filter=blob:none", url, dir,
                             out: File::NULL, err: File::NULL)
  end
  have = system("git", "-C", dir, "cat-file", "-e", "--quiet", "#{revision}^{commit}",
                out: File::NULL, err: File::NULL)
  unless have
    return nil unless system("git", "-C", dir, "fetch", "--quiet", "origin", revision,
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

args = ARGV.reject { |a| a.start_with?("--") }
unknown = args.uniq - manifest_ids
unless unknown.empty?
  warn "unknown case ids: #{unknown.join(' ')}"
  warn "PARITY-SUMMARY #{JSON.generate(expected: args.uniq.length, executed: 0, exact: 0, strict: 0, near: 0, defer: 0, skip: 0, fail: 0, missing: args.uniq.length)}"
  exit 1
end

ids = args.empty? ? manifest_ids : args.uniq.sort

def run_gate(ids)
  out, _err, status = Open3.capture3(
    RbConfig.ruby, File.expand_path("parity.rb", __dir__), "--only", ids.join(",")
  )
  [out, status.success?]
end

out, = run_gate(ids)
line = out[/^=== PARITY: (\d+)\/(\d+) pass \(byte-exact\)  \|  (\d+) diff  \|  (\d+) runtime-error  \|  (\d+) oracle-error ===$/, 0]
abort "parity-summary: could not parse scripts/parity.rb output\n#{out}" unless line

m = line.match(/^=== PARITY: (\d+)\/(\d+) pass \(byte-exact\)  \|  (\d+) diff  \|  (\d+) runtime-error  \|  (\d+) oracle-error ===$/)
passed, _requested, diff_count, error_count, oracle_count = m.captures.map(&:to_i)

if diff_count.zero? && error_count.zero? && oracle_count.zero?
  exact = passed
  fail_count = 0
  defer_count = 0
else
  # Classify per case so counts stay exact instead of inferring from groups.
  exact = 0
  fail_count = 0
  defer_count = 0
  ids.each do |cid|
    out1, ok1 = run_gate([cid])
    if out1.include?("ORACLE ERRORS")
      defer_count += 1
    elsif ok1
      exact += 1
    else
      fail_count += 1
    end
  end
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
