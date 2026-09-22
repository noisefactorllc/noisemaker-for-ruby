# frozen_string_literal: true

# Exact reference-image comparisons. Only optional external dependencies
# (the pinned JavaScript checkout and live CDN) may skip tests.

require "minitest/autorun"
require "json"
require "digest/sha2"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../scripts/oracle"

class TestParity < Minitest::Test
  include NoisemakerOracle::Tests
  PARITY_SCRIPT_PATH = File.expand_path("../scripts/parity.rb", __dir__)
  require_relative "../lib/noisemaker_cpu/renderer"
  require_relative "../lib/noisemaker_cpu/png"
  require_relative "../lib/noisemaker_cpu/transpiler/cdn"

  CPU_DIR = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path(File.join(__dir__, "..", "..", "noisemaker-for-cpu"))
  CLI = File.join(CPU_DIR, "bin", "noisemaker-cpu.js")

  # Cross-port bootstrap check: the perl port's committed lock, overridable via
  # NOISEMAKER_PERL_LOCK. Skips gracefully when absent -- the durable source
  # of truth for this repo's pins is its own committed bundle-lock.json.
  PERL_LOCK_PATH = ENV["NOISEMAKER_PERL_LOCK"]

  def setup
    @tmp_dir = Dir.mktmpdir("noisemaker-parity-test-")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  def js_effect(effect_id, *extra)
    out = File.join(@tmp_dir, "js.png")
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
    require_oracle
  end

  def test_lighting_default_surface_matches_javascript_on_a_nonuniform_image
    require_oracle
    bytes = (0...221).flat_map { |i| [i % 256, (i * 7) % 256, (i * 19) % 256, 255] }.pack("C*")
    input = NoisemakerCpu::Surface.from_rgba8(17, 13, bytes)
    source = File.join(@tmp_dir, "lighting-input.png")
    output = File.join(@tmp_dir, "lighting-output.png")
    File.binwrite(source, NoisemakerCpu::PNG.encode_png(input))
    _out, err, status = Open3.capture3("node", CLI, "apply", "filter/lighting", source,
      "--seed", "1", "--time", "0.25", "--output", output)
    assert status.success?, err
    expected = NoisemakerCpu::PNG.decode_png(File.binread(output))
    actual = NoisemakerCpu::Renderer.render_effect("filter/lighting", {}, { inputTex: input },
      width: 17, height: 13, seed: 1, time: 0.25)
    assert_equal expected.to_rgba8, actual.to_rgba8
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

  %w[filter/mosaicTiles filter/stipple filter/strokes].each do |effect_id|
    define_method("test_#{effect_id.tr('/', '_')}_canonical_rounding_is_byte_exact") do
      skip_unless_renderable
      js = js_effect(effect_id)
      solid = NoisemakerCpu::Renderer.render_effect("synth/solid", {}, nil, width: 8, height: 8, seed: 1, time: 0.25)
      rb = NoisemakerCpu::Renderer.render_effect(effect_id, {}, { "inputTex" => solid },
                                                  width: 8, height: 8, seed: 1, time: 0.25)
      assert_equal 0, max_diff(js, rb), "#{effect_id} canonical rounding byte-exact"
    end
  end


  # seeded generator (uint hash path)
  def test_synth_noise_byte_exact
    skip_unless_renderable

    js = js_effect("synth/noise")
    rb = NoisemakerCpu::Renderer.render_effect("synth/noise", {}, nil, width: 8, height: 8, seed: 1, time: 0.25)
    assert_equal 0, max_diff(js, rb), "synth/noise byte-exact"
  end

  def test_parity_script_exits_nonzero_on_oracle_failure
    missing_oracle = File.join(@tmp_dir, "missing-oracle")
    stdout, _stderr, status = Open3.capture3(
      { "NOISEMAKER_CPU_DIR" => missing_oracle },
      RbConfig.ruby, PARITY_SCRIPT_PATH, "--only", "synth/solid"
    )

    refute status.success?, stdout
    assert_includes stdout, "0/1 pass"
    assert_includes stdout, "1 oracle-error"
  end

  def test_parity_script_exits_nonzero_when_no_effects_are_selected
    stdout, _stderr, status = Open3.capture3(
      RbConfig.ruby, PARITY_SCRIPT_PATH, "--only", "not/an-effect"
    )

    refute status.success?, stdout
    assert_includes stdout, "0/0 pass"
  end

  def test_parity_script_exits_nonzero_when_some_requested_effects_are_unknown
    cpu_dir = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path("../../noisemaker-for-cpu", __dir__)
    cli = File.join(cpu_dir, "bin", "noisemaker-cpu.js")
    require_oracle

    stdout, _stderr, status = Open3.capture3(
      { "NOISEMAKER_CPU_DIR" => cpu_dir },
      RbConfig.ruby, PARITY_SCRIPT_PATH, "--only", "synth/solid,not/an-effect"
    )

    refute status.success?, stdout
    assert_includes stdout, "UNKNOWN EFFECTS"
    assert_includes stdout, "not/an-effect"
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
    skip "live CDN tests require NOISEMAKER_LIVE_CDN=1" unless ENV["NOISEMAKER_LIVE_CDN"] == "1"
  end

  # Offline unit test for _json5_decode's number grammar -- no network
  # needed. This is the coordinator's exact repro for the exponent-literal
  # corruption bug: before the fix, the bare "e"/"E" of an exponent (e.g.
  # `1e3`) was misidentified by the bare-identifier branch as a value
  # bareword and replaced with "0", corrupting `1e3`->`10`, `2E+4`->`204`,
  # `-1e3`->`-10`, and leaving `1.5e-7` with a dangling, unparseable "-7".
  def test_json5_decode_number_grammar

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
    skip "perl reference lock not configured (set NOISEMAKER_PERL_LOCK to enable)" unless PERL_LOCK_PATH && File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.binread(PERL_LOCK_PATH))["hashes"]
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
    skip "perl reference lock not configured (set NOISEMAKER_PERL_LOCK to enable)" unless PERL_LOCK_PATH && File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.binread(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("synth/solid", perl_hashes, version_dir)
  end

  # classicNoisedeck/colorLab: a second, heavier live exercise of the
  # leading-dot-decimal fix -- its `globals` palette table contains dozens
  # of `.NN` entries (e.g. `[.83,.6,.63]`), not just the 2-3 in synth/solid.
  def test_cdn_live_hash_classic_noisedeck_color_lab
    skip_unless_cdn_live_ready
    skip "perl reference lock not configured (set NOISEMAKER_PERL_LOCK to enable)" unless PERL_LOCK_PATH && File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.binread(PERL_LOCK_PATH))["hashes"]
    version_dir = NoisemakerCpu::Transpiler::CDN._cache_dir(NoisemakerCpu::Transpiler::CDN::CDN_VERSION)
    verify_effect_hash_and_roundtrip("classicNoisedeck/colorLab", perl_hashes, version_dir)
  end

  # mixer/blendMode: the 4th effect of the coordinator-required spread
  # (synth/*, filter/*, classicNoisedeck/*, mixer/*). Its globals have no
  # leading-dot decimals, so this is a clean control alongside the other 3.
  def test_cdn_live_hash_mixer_blend_mode
    skip_unless_cdn_live_ready
    skip "perl reference lock not configured (set NOISEMAKER_PERL_LOCK to enable)" unless PERL_LOCK_PATH && File.exist?(PERL_LOCK_PATH)

    perl_hashes = JSON.parse(File.binread(PERL_LOCK_PATH))["hashes"]
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

  def test_cpu_upstream_source_lock_and_snapshot_parity
    source_lock_path = File.join(CPU_DIR, "scripts", "upstream", "source-lock.js")
    snapshot_path = File.join(CPU_DIR, "src", "effects", "generated", "upstream-snapshot.js")
    require_oracle

    source_lock_text = File.binread(source_lock_path)
    assert_includes source_lock_text, "export const PINNED_UPSTREAM_REVISION = '#{NoisemakerOracle::LOCK.fetch('upstreamRevision')}'"
    assert_includes source_lock_text, "export const PINNED_SOURCE_DIGEST = '#{NoisemakerOracle::LOCK.fetch('sourceDigest')}'"

    snapshot_text = File.binread(snapshot_path)
    assert_includes snapshot_text, "export const UPSTREAM_REVISION = \"#{NoisemakerOracle::LOCK.fetch('upstreamRevision')}\""
  end
end
