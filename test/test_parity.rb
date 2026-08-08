# frozen_string_literal: true

# Mirror of t/05-parity.t (Perl): Ruby renders must match the JS oracle
# byte-for-byte on a fast subset (the full 167-effect sweep lives in
# scripts/parity.rb). Guarded to skip gracefully -- rather than fail -- when
# a dependency this worker doesn't own isn't ready yet: the JS oracle itself
# (mirrors perl's `plan skip_all`), Worker C/D's renderer.rb/png.rb, and the
# generated bundle (lib/noisemaker_cpu/bundle/, produced by
# scripts/build-bundle.rb --all, which itself needs Worker B's transpiler).
#
# test_cdn_live is NOT a perl mirror (perl's t/ has no CDN test) -- it is
# this worker's own scoped live-network check per the port coordinator's
# instructions: fetch a couple of effects + the manifest from the real CDN,
# verify the sha256 of each fetched GLSL program against perl's committed
# lock (proving the CDN still serves the pinned content Perl transpiled
# against), and confirm the disk cache round-trips. Mirrors how the Python
# port's tests/test_cdn.py rescues CDNError -> skip when offline.

require "minitest/autorun"
require "json"
require "digest/sha2"
require "tmpdir"
require "fileutils"

class TestParity < Minitest::Test
  RENDERER_PATH = File.expand_path("../lib/noisemaker_cpu/renderer.rb", __dir__)
  PNG_PATH = File.expand_path("../lib/noisemaker_cpu/png.rb", __dir__)
  BUNDLE_METADATA_PATH = File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__)
  RENDER_DEPS_READY = File.exist?(RENDERER_PATH) && File.exist?(PNG_PATH)

  require_relative "../lib/noisemaker_cpu/renderer" if RENDER_DEPS_READY
  require_relative "../lib/noisemaker_cpu/png" if RENDER_DEPS_READY

  CDN_PATH = File.expand_path("../lib/noisemaker_cpu/transpiler/cdn.rb", __dir__)
  COMPUTED_DEFS_PATH = File.expand_path("../lib/noisemaker_cpu/transpiler/computed_defs.rb", __dir__)
  CDN_DEPS_READY = File.exist?(CDN_PATH) && File.exist?(COMPUTED_DEFS_PATH)

  require_relative "../lib/noisemaker_cpu/transpiler/cdn" if CDN_DEPS_READY

  CPU_DIR = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path(File.join(__dir__, "..", "..", "noisemaker-cpu"))
  CLI = File.join(CPU_DIR, "bin", "noisemaker-cpu.js")

  # Session-scoped reference path for the perl port's "PRIMARY template"
  # (docs/2026-08-08-ruby-port-contract.md) -- override via
  # NOISEMAKER_PERL_LOCK once the perl port lands at a durable
  # (non-scratchpad) location. Skips gracefully when absent so this never
  # becomes a false failure later.
  PERL_LOCK_PATH = ENV["NOISEMAKER_PERL_LOCK"] ||
                   "/private/tmp/claude-502/-Users-alex-platform-scaffold/6cd0af2e-26f9-432d-84b6-539d2b8d9983/" \
                   "scratchpad/noisemaker-for-perl/lib/Math/Fractal/Noisemaker/bundle/bundle-lock.json"

  TMP_DIR = Dir.mktmpdir
  at_exit { FileUtils.remove_entry(TMP_DIR) }

  def oracle_available?
    File.exist?(CLI) && system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def js_effect(effect_id, *extra)
    out = File.join(TMP_DIR, "js.png")
    cmd = ["node", CLI, "effect", effect_id,
           "--width", "8", "--height", "8", "--seed", "1", "--time", "0.25",
           "--output", out] + extra
    ok = system(*cmd, out: File::NULL, err: File::NULL)
    raise "oracle failed\n" unless ok

    NoisemakerCpu::PNG.decode_png(File.binread(out))
  end

  def max_diff(a, b)
    x = a.to_rgba8.unpack("C*")
    y = b.to_rgba8.unpack("C*")
    d = 0
    x.each_index do |i|
      v = (x[i] - y[i]).abs
      d = v if v > d
    end
    d
  end

  def skip_unless_renderable
    skip "renderer.rb/png.rb not yet present (Worker C/D pending)" unless RENDER_DEPS_READY
    skip "JS oracle (node + noisemaker-cpu) not available" unless oracle_available?
    skip "bundle not yet generated (lib/noisemaker_cpu/bundle/metadata.json missing)" unless File.exist?(BUNDLE_METADATA_PATH)
  end

  # generator with params
  def test_synth_solid_byte_exact
    skip_unless_renderable

    js = js_effect("synth/solid", "--param", "color=#4080c0")
    rb = NoisemakerCpu::Renderer.render_effect("synth/solid", { "color" => "#4080c0" }, nil,
                                                width: 8, height: 8, seed: 1, time: 0.25)
    assert_equal 0, max_diff(js, rb), "synth/solid byte-exact"
  end

  # filter over the oracle's default solid
  def test_filter_invert_byte_exact
    skip_unless_renderable

    js = js_effect("filter/invert")
    solid = NoisemakerCpu::Renderer.render_effect("synth/solid", {}, nil, width: 8, height: 8, seed: 1, time: 0.25)
    rb = NoisemakerCpu::Renderer.render_effect("filter/invert", {}, { "inputTex" => solid },
                                                width: 8, height: 8, seed: 1, time: 0.25)
    assert_equal 0, max_diff(js, rb), "filter/invert byte-exact"
  end

  # seeded generator (uint hash path)
  def test_synth_noise_byte_exact
    skip_unless_renderable

    js = js_effect("synth/noise")
    rb = NoisemakerCpu::Renderer.render_effect("synth/noise", {}, nil, width: 8, height: 8, seed: 1, time: 0.25)
    assert_equal 0, max_diff(js, rb), "synth/noise byte-exact"
  end

  # Not a perl mirror -- see file header. Scoped live-CDN checks: fetch a
  # couple of effects + the manifest, verify sha256 against perl's committed
  # lock, confirm the disk cache round-trips (second fetch hits disk).
  #
  # Network-layer failures (unreachable host, non-2xx) skip gracefully --
  # mirroring the Python port's tests/test_cdn.py, which rescues its own
  # CDNError (network) but lets a plain ValueError (parse failure) surface
  # as a real test failure. cdn.rb/CDN.pm don't have distinct exception
  # classes (perl `die "string"` / Ruby `raise "string"` throughout), so
  # #network_error? approximates that same split by message prefix -- every
  # error CDN.rb raises is prefixed "CDN ", but only the network-layer ones
  # (from _fetch_text) look like "CDN request failed ..." / "CDN <code> ...".

  def network_error?(message)
    msg = message.to_s
    msg.start_with?("CDN request failed") || !!(msg =~ /\ACDN \d+ /)
  end

  def skip_unless_cdn_live_ready
    skip "cdn.rb requires Worker B's transpiler/computed_defs.rb (not yet present)" unless CDN_DEPS_READY
  end

  # Fetches effect_id live, verifies every program's sha256 against perl's
  # committed lock, and confirms a second fetch hits the disk cache (mtime
  # unchanged, identical result) rather than re-fetching.
  def verify_effect_hash_and_roundtrip(effect_id, perl_hashes, version_dir)
    effect =
      begin
        NoisemakerCpu::Transpiler::CDN.fetch_effect(effect_id)
      rescue StandardError => e
        skip "shaders.noisedeck.app unreachable: #{e.message}" if network_error?(e.message)
        raise
      end

    cache_path = File.join(version_dir, "effects", "#{effect_id}.json")
    assert File.exist?(cache_path), "expected #{effect_id} to be cached to disk at #{cache_path}"
    mtime_before = File.mtime(cache_path)

    effect["passes"].each do |p|
      program = p["program"]
      glsl = effect["programs"][program]
      next if glsl.nil? # CPU-only draw-mode pass -- no GLSL/hash to verify

      key = "#{effect_id}:#{program}"
      digest = Digest::SHA256.hexdigest(glsl.strip)
      expected = perl_hashes[key]
      refute_nil expected, "perl lock has no entry for #{key} -- lock/effect drift, check bundle-lock.json"
      assert_equal expected, digest,
                   "sha256 MISMATCH for #{key}: live CDN content diverges from perl's committed " \
                   "bundle-lock.json (ruby=#{digest} perl=#{expected})"
    end

    # Cache round-trip: a second fetch_effect for the same id must read the
    # disk cache rather than re-fetching (mtime must not change).
    second = NoisemakerCpu::Transpiler::CDN.fetch_effect(effect_id)
    assert_equal effect, second, "second fetch_effect should return identical data (cache round-trip)"
    assert_equal mtime_before, File.mtime(cache_path),
                 "second fetch_effect should hit the disk cache, not re-fetch (cache file mtime changed)"
  end

  def test_cdn_live_manifest
    skip_unless_cdn_live_ready

    manifest =
      begin
        NoisemakerCpu::Transpiler::CDN.fetch_manifest
      rescue StandardError => e
        skip "shaders.noisedeck.app unreachable: #{e.message}" if network_error?(e.message)
        raise
      end
    assert_kind_of Hash, manifest
    assert manifest.key?("synth/solid"), "manifest should list synth/solid"
    assert manifest.key?("filter/invert"), "manifest should list filter/invert"
  end

  # filter/invert's globals contain no JS bare-decimal number literals, so
  # this exercises the full happy path: live fetch, sha256 match against
  # perl's committed bundle-lock.json, disk-cache round-trip.
  def test_cdn_live_hash_filter_invert
    skip_unless_cdn_live_ready
    skip "perl reference lock not found at #{PERL_LOCK_PATH}" unless File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.read(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("filter/invert", perl_hashes, version_dir)
  end

  # KNOWN, CONFIRMED gap -- characterizes rather than verifies. synth/solid's
  # live `globals` contains `default:[.5,.5,.5]` (JS's bare-leading-dot
  # decimal shorthand for 0.5). Perl's Transpiler/CDN.pm _json5_decode --
  # which this file's cdn.rb translates 1:1 -- has no number-literal
  # handling at all (only string/identifier/comma/plus-sign special cases),
  # so `.5` reaches JSON::PP / Ruby's JSON as-is and both reject it as
  # invalid strict JSON. Verified empirically against perl's real CDN.pm
  # (`perl -Ilib -MMath::Fractal::Noisemaker::Transpiler::CDN=fetch_effect`)
  # here in this session: identical failure, identical message. The raw
  # live bundle really does contain `.5,.5,.5` (confirmed via curl), not
  # `0.5,0.5,0.5`. The Python port sidesteps this by using a real `json5`
  # library instead of a hand-rolled subset (JSON5's grammar explicitly
  # allows a leading-dot decimal; its own test_cdn.py asserts synth/solid's
  # color default parses to [0.5, 0.5, 0.5]).
  #
  # Translation doctrine ("no innovation") says this port doesn't get to
  # silently add number-normalization perl's CDN.pm lacks -- a fix belongs
  # in perl's _json5_decode first, then gets ported here identically. This
  # test characterizes the current, confirmed behavior so it fails loudly
  # (telling whoever fixes the upstream gap to replace this with a real
  # verify_effect_hash_and_roundtrip call) rather than silently skipping.
  def test_cdn_live_hash_synth_solid
    skip_unless_cdn_live_ready

    begin
      NoisemakerCpu::Transpiler::CDN.fetch_effect("synth/solid")
      flunk "fetch_effect('synth/solid') succeeded -- the known JSON5 bare-decimal gap looks fixed; " \
            "replace this characterization test with a real verify_effect_hash_and_roundtrip call " \
            "(see test_cdn_live_hash_filter_invert)"
    rescue StandardError => e
      # Minitest::Assertion (from flunk above) is not a StandardError -- it
      # inherits directly from Exception, so it is never caught here.
      skip "shaders.noisedeck.app unreachable: #{e.message}" if network_error?(e.message)
      assert_match(/could not parse 'globals'/, e.message)
      assert_match(/\.5,\s*\.5,\s*\.5/, e.message,
                   "expected the known bare-decimal ('.5') JSON5 gap -- error text changed, " \
                   "re-check whether this is still the same issue")
    end
  end
end
