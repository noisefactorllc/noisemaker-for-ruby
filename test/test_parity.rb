# frozen_string_literal: true

# Mirror of t/05-parity.t (Perl): Ruby renders must match the JS oracle
# byte-for-byte on a fast subset (the full 167-effect sweep lives in
# scripts/parity.rb). Guarded to skip gracefully -- rather than fail -- when
# a dependency this worker doesn't own isn't ready yet: the JS oracle itself
# (mirrors perl's `plan skip_all`), Worker C/D's renderer.rb/png.rb, and the
# generated bundle (lib/noisemaker_cpu/bundle/, produced by
# scripts/build-bundle.rb --all, which itself needs Worker B's transpiler).
#
# test_cdn_live_* is NOT a perl mirror (perl's t/ has no CDN test) -- it is
# this worker's own scoped live-network check per the port coordinator's
# instructions: fetch a small spread of effects (synth/solid, filter/invert,
# classicNoisedeck/colorLab, mixer/blendMode) + the manifest from the real
# CDN, verify the sha256 of each fetched GLSL program against perl's
# committed lock (proving the CDN still serves the pinned content Perl
# transpiled against), and confirm the disk cache round-trips -- cold and
# warm fetches must derive identical data, including paramOrder. Mirrors how
# the Python port's tests/test_cdn.py rescues CDNError -> skip when offline.

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

  # Cross-port bootstrap check: the perl port's committed lock, expected at a
  # sibling checkout (same convention as NOISEMAKER_CPU_DIR), overridable via
  # NOISEMAKER_PERL_LOCK. Skips gracefully when absent -- the durable source
  # of truth for this repo's pins is its own committed bundle-lock.json.
  PERL_LOCK_PATH = ENV["NOISEMAKER_PERL_LOCK"] ||
                   File.expand_path("../../noisemaker-for-perl/lib/Math/Fractal/Noisemaker/bundle/bundle-lock.json",
                                    __dir__)

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

  # Offline unit test for _json5_decode's number grammar -- no network
  # needed. This is the coordinator's exact repro for the exponent-literal
  # corruption bug: before the fix, the bare "e"/"E" of an exponent (e.g.
  # `1e3`) was misidentified by the bare-identifier branch as a value
  # bareword and replaced with "0", corrupting `1e3`->`10`, `2E+4`->`204`,
  # `-1e3`->`-10`, and leaving `1.5e-7` with a dangling, unparseable "-7".
  def test_json5_decode_number_grammar
    skip "cdn.rb requires Worker B's transpiler/computed_defs.rb (not yet present)" unless CDN_DEPS_READY

    result = NoisemakerCpu::Transpiler::CDN._json5_decode("{a:1e3,b:1.5e-7,c:.5,d:-1e3,e:2E+4,f:1001}")
    assert_equal 1000, result["a"]
    assert_equal 1.5e-7, result["b"]
    assert_equal 0.5, result["c"]
    assert_equal(-1000, result["d"])
    assert_equal 20000, result["e"]
    assert_equal 1001, result["f"]
    assert_kind_of Integer, result["f"], "a plain integer literal should decode as JSON's Integer class"
    assert_kind_of Float, result["a"], "an exponent literal should decode as JSON's Float class"

    # A handful of individually-named cases, for a clearer failure signal
    # than the combined repro above if the grammar regresses on just one.
    {
      "1e3" => 1000, "1E3" => 1000, "2E+4" => 20000, "1e-3" => 0.001,
      "-1e3" => -1000, "1.5e-7" => 1.5e-7, ".5" => 0.5, "-.5" => -0.5,
      "0.5" => 0.5, "1.5" => 1.5, "1001" => 1001, "-1001" => -1001,
      "+5" => 5, "0" => 0, ".5e3" => 500,
    }.each do |literal, expected|
      decoded = NoisemakerCpu::Transpiler::CDN._json5_decode("[#{literal}]").first
      assert_equal expected, decoded, "_json5_decode(#{literal.inspect}) should be #{expected}"
    end
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

    refute_empty effect["paramOrder"], "#{effect_id}: paramOrder should not be empty on a fresh fetch " \
                                        "(ordered_object_keys bareword-key fix)"

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
    # disk cache rather than re-fetching (mtime must not change), and must
    # return identical data on every field -- including paramOrder, now
    # that ordered_object_keys recognizes bareword keys (see
    # test_cdn_live_param_order_cold_equals_warm for a dedicated,
    # cache-cleared check of that specifically).
    second = NoisemakerCpu::Transpiler::CDN.fetch_effect(effect_id)
    assert_equal mtime_before, File.mtime(cache_path),
                 "second fetch_effect should hit the disk cache, not re-fetch (cache file mtime changed)"
    %w[id namespace func params paramOrder passes textures programs externalTexture].each do |field|
      if effect[field].nil?
        assert_nil second[field], "field #{field.inspect} should round-trip identically"
      else
        assert_equal effect[field], second[field], "field #{field.inspect} should round-trip identically"
      end
    end
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
  # this exercised the full happy path even before the cdn.rb fixes below.
  def test_cdn_live_hash_filter_invert
    skip_unless_cdn_live_ready
    skip "perl reference lock not found at #{PERL_LOCK_PATH}" unless File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.read(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("filter/invert", perl_hashes, version_dir)
  end

  # synth/solid's live `globals` contains `default:[.5,.5,.5]` (JS's
  # bare-leading-dot decimal shorthand for 0.5) and `randMin:.5` -- this is
  # exactly the construct cdn.rb's _json5_decode now normalizes (see the
  # DELIBERATE DEVIATION FROM PERL comment there). Was a characterization-
  # of-failure test before that fix landed; now a real verification.
  def test_cdn_live_hash_synth_solid
    skip_unless_cdn_live_ready
    skip "perl reference lock not found at #{PERL_LOCK_PATH}" unless File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.read(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("synth/solid", perl_hashes, version_dir)
  end

  # classicNoisedeck/colorLab: a second, heavier live exercise of the
  # leading-dot-decimal fix -- its `globals` palette table contains dozens
  # of `.NN` entries (e.g. `[.83,.6,.63]`), not just the 2-3 in synth/solid.
  def test_cdn_live_hash_classic_noisedeck_color_lab
    skip_unless_cdn_live_ready
    skip "perl reference lock not found at #{PERL_LOCK_PATH}" unless File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.read(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("classicNoisedeck/colorLab", perl_hashes, version_dir)
  end

  # mixer/blendMode: the 4th effect of the coordinator-required spread
  # (synth/*, filter/*, classicNoisedeck/*, mixer/*). Its globals have no
  # leading-dot decimals, so this is a clean control alongside the other 3.
  def test_cdn_live_hash_mixer_blend_mode
    skip_unless_cdn_live_ready
    skip "perl reference lock not found at #{PERL_LOCK_PATH}" unless File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.read(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("mixer/blendMode", perl_hashes, version_dir)
  end

  # ordered_object_keys now recognizes bareword (unquoted) keys (see the
  # DELIBERATE DEVIATION FROM PERL comment on that method in cdn.rb), so a
  # genuinely cold fetch (cache forcibly cleared first) must derive the same
  # paramOrder a warm one does -- was a characterization-of-failure test
  # before that fix landed; now asserts cold == warm, both non-empty, and
  # matches the known-correct value.
  def test_cdn_live_param_order_cold_equals_warm
    skip_unless_cdn_live_ready

    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    cache_path = File.join(version_dir, "effects", "filter/invert.json")
    FileUtils.rm_f(cache_path) # force a genuinely cold fetch for this specific check

    cold =
      begin
        NoisemakerCpu::Transpiler::CDN.fetch_effect("filter/invert")
      rescue StandardError => e
        skip "shaders.noisedeck.app unreachable: #{e.message}" if network_error?(e.message)
        raise
      end
    refute_empty cold["paramOrder"], "cold fetch_effect('filter/invert') should not return an empty paramOrder"
    assert_equal ["mode"], cold["paramOrder"], "cold fetch should derive filter/invert's known paramOrder"

    warm = NoisemakerCpu::Transpiler::CDN.fetch_effect("filter/invert")
    assert_equal cold["paramOrder"], warm["paramOrder"], "cold and warm fetches must derive identical paramOrder"
  end
end
