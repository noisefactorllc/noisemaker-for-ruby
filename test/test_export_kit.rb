# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestExportKit < Minitest::Test
  def test_export_kit_config_points_to_valid_metadata
    config_path = File.expand_path("../export-kit/kit.config.json", __dir__)
    assert File.exist?(config_path), "export-kit/kit.config.json must exist"
    config = JSON.parse(File.binread(config_path))

    metadata_rel = config.dig("compat", "fromBundleMetadata")
    assert metadata_rel, "compat.fromBundleMetadata must be configured"
    metadata_path = File.expand_path("../#{metadata_rel}", __dir__)
    assert File.exist?(metadata_path), "#{metadata_rel} must exist"

    metadata = JSON.parse(File.binread(metadata_path))
    assert_equal 210, metadata.fetch("effects").length, "expected 210 bundled effects"
  end

  # The exported kit's run.rb reports invalid input like the installed CLI: the
  # message alone, no backtrace, exit 2 (exit 1 for other failures).
  def test_kit_run_reports_invalid_input_without_a_backtrace
    root = File.expand_path("..", __dir__)
    Dir.mktmpdir("nm-ruby-kit") do |kit|
      FileUtils.cp(File.join(root, "export-kit/kit/run.rb"), kit)
      FileUtils.mkdir_p(File.join(kit, "engine"))
      FileUtils.cp_r(File.join(root, "lib"), File.join(kit, "engine", "lib"))
      File.write(File.join(kit, "ok.dsl"), "search synth\nsolid().write(o0)\nrender(o0)\n")
      File.write(File.join(kit, "bad.dsl"), "search synth\nnosucheffect().write(o0)\nrender(o0)\n")
      run = lambda do |*args|
        Open3.capture3(RbConfig.ruby, "run.rb", *args, "--output", "out.png", chdir: kit)
      end
      [
        [%w[bad.dsl --width 8 --height 8], 2, /nosucheffect/],
        [%w[ok.dsl --width 0 --height 8], 2, /--width must be a positive integer/],
        [%w[ok.dsl --width abc], 2, /invalid argument: --width abc/],
        [%w[missing.dsl], 1, /cannot read missing\.dsl/]
      ].each do |args, code, message|
        _out, err, status = run.call(*args)
        assert_equal code, status.exitstatus, "#{args.join(" ")}: #{err}"
        assert_match message, err
        refute_match(/\.rb:\d+:in /, err, "#{args.join(" ")} printed a backtrace")
      end
      out, err, status = run.call("ok.dsl", "--width", "8", "--height", "8")
      assert status.success?, err
      assert_match(/Rendered 8x8/, out)
    end
  end
end
