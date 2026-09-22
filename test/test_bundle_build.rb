# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/noisemaker_cpu/transpiler/build"

class TestBundleBuild < Minitest::Test
  Build = NoisemakerCpu::Transpiler::Build
  CDN = NoisemakerCpu::Transpiler::CDN

  def setup
    @dir = Dir.mktmpdir("noisemaker-build-test-")
    @bundle = File.join(@dir, "bundle")
    @fetch = CDN.method(:fetch_effect)
    @effect = {
      "namespace" => "synth", "func" => "probe", "params" => {},
      "passes" => [{ "program" => "probe", "outputs" => { "fragColor" => "outputTex" } }],
      "programs" => { "probe" => "out vec4 fragColor; void main() { fragColor = vec4(0.0); }" }
    }
    effect = @effect
    CDN.define_singleton_method(:fetch_effect) { |_id| effect }
    Build.build(["synth/probe"], out_dir: @bundle)
    @before = snapshot
  end

  def teardown
    CDN.define_singleton_method(:fetch_effect, @fetch)
    FileUtils.remove_entry(@dir)
  end

  def snapshot
    Dir.glob("**/*", base: @bundle).select { |path| File.file?(File.join(@bundle, path)) }
      .to_h { |path| [path, File.binread(File.join(@bundle, path))] }
  end

  def test_rejected_drift_preserves_every_published_byte
    @effect["programs"]["probe"] = @effect["programs"]["probe"].sub("0.0", "0.5")
    assert_raises(StandardError, SystemExit) { Build.build(["synth/probe"], out_dir: @bundle) }
    assert_equal @before, snapshot
  end

  def test_fetch_failure_preserves_previous_bundle_and_fails
    CDN.define_singleton_method(:fetch_effect) { |_id| raise "network unavailable" }
    assert_raises(StandardError) { Build.build(["synth/probe"], out_dir: @bundle) }
    assert_equal @before, snapshot
  end

  def test_missing_effect_cannot_publish_an_empty_bundle
    CDN.define_singleton_method(:fetch_effect) { |_id| nil }
    assert_raises(StandardError) { Build.build(["synth/probe"], out_dir: @bundle) }
    assert_equal @before, snapshot
  end

  def test_a_missing_or_invalid_pass_cannot_publish_a_partial_effect
    [nil, "this is not a shader"].each do |source|
      @effect["passes"] << { "program" => "broken", "outputs" => { "fragColor" => "outputTex" } }
      @effect["programs"]["broken"] = source
      assert_raises(StandardError) { Build.build(["synth/probe"], out_dir: @bundle) }
      assert_equal @before, snapshot
      @effect["passes"].pop
    end
  end

  def test_empty_selection_cannot_erase_a_bundle
    assert_raises(ArgumentError) { Build.build([], out_dir: @bundle) }
    assert_equal @before, snapshot
  end

  def test_failed_install_restores_the_previous_bundle
    rename = File.method(:rename)
    bundle = @bundle
    File.define_singleton_method(:rename) do |source, target|
      raise Errno::EACCES, "simulated install failure" if source.end_with?("/bundle") && target == bundle
      rename.call(source, target)
    end
    assert_raises(Errno::EACCES) { Build.build(["synth/probe"], out_dir: @bundle) }
    assert_equal @before, snapshot
  ensure
    File.define_singleton_method(:rename, rename)
  end

  def test_interrupt_during_install_restores_the_previous_bundle
    rename = File.method(:rename)
    bundle = @bundle
    File.define_singleton_method(:rename) do |source, target|
      raise Interrupt if source.end_with?("/bundle") && target == bundle
      rename.call(source, target)
    end
    assert_raises(Interrupt) { Build.build(["synth/probe"], out_dir: @bundle) }
    assert_equal @before, snapshot
  ensure
    File.define_singleton_method(:rename, rename)
  end

  def test_failed_rollback_preserves_backup_for_recovery
    rename = File.method(:rename)
    bundle = @bundle
    File.define_singleton_method(:rename) do |source, target|
      raise Errno::EACCES, "simulated destination failure" if target == bundle
      rename.call(source, target)
    end
    error = assert_raises(StandardError) { Build.build(["synth/probe"], out_dir: @bundle) }
    backup = Dir.glob(File.join(@dir, ".noisemaker-build-*", "previous")).first
    refute_nil backup, "keep the only remaining copy when restoration is blocked"
    assert_equal @before.fetch("metadata.json"), File.binread(File.join(backup, "metadata.json"))
    assert_includes error.message, backup
  ensure
    File.define_singleton_method(:rename, rename)
  end

  def test_accepted_update_publishes_matching_kernel_and_lock
    @effect["programs"]["probe"] = @effect["programs"]["probe"].sub("0.0", "0.5")
    Build.build(["synth/probe"], out_dir: @bundle, update_lock: true)
    after = snapshot
    refute_equal @before.fetch("kernels/ruby/synth__probe__probe.rb"), after.fetch("kernels/ruby/synth__probe__probe.rb")
    lock = JSON.parse(after.fetch("bundle-lock.json"))
    assert_equal Digest::SHA256.hexdigest(@effect["programs"]["probe"]), lock["hashes"]["synth/probe:probe"]
  end
end
