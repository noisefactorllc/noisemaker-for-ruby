# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class TestPackaging < Minitest::Test
  def test_source_archive_build_installs_a_working_gem_and_bundler_entrypoint
    Dir.mktmpdir("noisemaker-package-") do |dir|
      root = File.expand_path("..", __dir__)
      %w[lib exe LICENSE README.md noisemaker-for-ruby.gemspec].each do |path|
        FileUtils.cp_r(File.join(root, path), dir)
      end
      env = ENV.keys.grep(/\ABUNDLE/).to_h { |key| [key, nil] }.merge(
        "GEM_HOME" => File.join(dir, "gems"), "GEM_PATH" => File.join(dir, "gems"),
        "RUBYLIB" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"))
      run = lambda do |*args|
        out, err, status = Open3.capture3(env, RbConfig.ruby, *args, chdir: dir)
        assert status.success?, "#{args.join(' ')} failed: #{out}\n#{err}"
        out
      end
      run.call("-S", "gem", "build", "noisemaker-for-ruby.gemspec")
      gem = Dir.glob(File.join(dir, "*.gem")).fetch(0)
      run.call("-S", "gem", "install", "--local", "--no-document", gem)
      run.call("-e", 'require "noisemaker_cpu"; puts NoisemakerCpu::Renderer.render_effect("synth/solid", {}, nil, width: 2, height: 2).to_rgba8.bytesize')
      File.write(File.join(dir, "Gemfile"), "gem 'noisemaker-for-ruby'\n")
      output = run.call("-rbundler/setup", "-e", 'Bundler.require; puts NoisemakerCpu::Renderer.meta.fetch("effects").size')
      assert_equal "210", output.strip
    end
  end

  # The README hands developers the live reports: the compatibility report is
  # the open issue labelled compatibility, and the gap register is the set of
  # issues labelled gap. Repository files are not the current report.
  def test_readme_points_to_the_live_compatibility_report_and_gap_issues
    readme = File.read(File.expand_path("../README.md", __dir__), encoding: "UTF-8")
    assert readme.include?("https://github.com/noisefactorllc/noisemaker-for-ruby/issues/3"),
           "README must link the live compatibility report issue"
    assert readme.include?("https://github.com/noisefactorllc/noisemaker-for-ruby/issues?q=label%3Agap"),
           "README must link the issues labelled gap"
    refute_match(/docs\/COMPATIBILITY\.md|docs\/COMPLETION_GAPS\.md/, readme,
                 "README must not name the removed historical documents as reports")
  end
end
