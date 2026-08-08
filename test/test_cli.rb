# frozen_string_literal: true

# Mirror of t/07-cli.t (Perl), assertion-for-assertion, adapted to Ruby /
# minitest. Exercises exe/noisemaker-rb as a subprocess (never in-process),
# the same way an end user invokes it -- shell-free (Open3 with an argv
# array), so args like "color=#f30" need no quoting/escaping.
#
# Every CLI path that resolves a real effect id reads the committed bundle
# eagerly (even error paths like "--param without =", since `_prologue`
# resolves the effect -- and therefore calls Renderer.meta -- before params
# are ever parsed; this mirrors bin/make-noise's own statement order
# exactly).

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"

DIST_ROOT = File.expand_path("..", __dir__)
NOISEMAKER_RB = File.join(DIST_ROOT, "exe", "noisemaker-rb")
RUBY_BIN = "/opt/homebrew/opt/ruby/bin/ruby"

# Run exe/noisemaker-rb as a subprocess. Returns [exit_code, stdout, stderr].
# opts: stdin: STRING, env: { "VAR" => "VALUE" } (merged over the current
# environment, mirroring Perl's `local %ENV = %ENV; $ENV{PATH} = ...`).
def run_cli(args, stdin: nil, env: {})
  stdout_str, stderr_str, status = Open3.capture3(
    env, RUBY_BIN, NOISEMAKER_RB, *args.map(&:to_s), stdin_data: stdin || ""
  )
  [status.exitstatus, stdout_str, stderr_str]
end

class TestCli < Minitest::Test
  def test_executable_exists_and_is_executable
    assert File.file?(NOISEMAKER_RB), "exe/noisemaker-rb should exist"
    assert File.executable?(NOISEMAKER_RB), "exe/noisemaker-rb should be executable"
  end

  # --- --help / --version / no-args / unknown command -----------------------
  # None of these resolve an effect id, so none touch the bundle.

  def test_help_exits_zero_and_mentions_all_commands
    rc, out, _err = run_cli(["--help"])
    assert_equal 0, rc
    assert_match(/\bgenerate\b/, out)
    assert_match(/\bapply\b/, out)
    assert_match(/\banimate\b/, out)
    assert_match(/\brun\b/, out)
  end

  def test_no_args_exits_zero_and_mentions_generate
    rc, out, _err = run_cli([])
    assert_equal 0, rc
    assert_match(/\bgenerate\b/, out)
  end

  def test_version_exits_zero_and_prints_expected_string
    rc, out, _err = run_cli(["--version"])
    assert_equal 0, rc
    # Adapted from Perl's "make-noise (Math::Fractal::Noisemaker) 1.000":
    # this port's identity is gem noisemaker-for-ruby, module NoisemakerCpu,
    # version 0.0.0 (contract "Identity & toolchain").
    assert_match(/noisemaker-rb \(NoisemakerCpu\) 0\.0\.0/, out)
  end

  def test_unknown_command_exits_nonzero
    rc, _out, err = run_cli(["bogus-command"])
    assert_equal 2, rc
    assert_match(/Unknown command/, err)
  end

  def test_subcommand_help_exits_zero
    %w[generate apply animate run].each do |cmd|
      rc, out, _err = run_cli([cmd, "--help"])
      assert_equal 0, rc, "#{cmd} --help should exit 0"
      assert_match(/\bgenerate\b/, out)
    end
  end

  # --- argument/flag errors that raise before any effect lookup -------------

  def test_generate_missing_effect_argument_exits_nonzero
    rc, _out, err = run_cli(["generate"])
    assert_equal 2, rc
    assert_match(/Missing argument 'EFFECT'/, err)
  end

  def test_apply_missing_effect_argument_exits_nonzero
    rc, _out, err = run_cli(["apply"])
    assert_equal 2, rc
    assert_match(/Missing argument 'EFFECT'/, err)
  end

  def test_apply_missing_input_filename_argument_exits_nonzero
    rc, _out, err = run_cli(["apply", "filter/invert"])
    assert_equal 2, rc
    assert_match(/Missing argument 'INPUT_FILENAME'/, err)
  end

  def test_apply_nonexistent_input_file_exits_nonzero
    rc, _out, err = run_cli(["apply", "filter/invert", "/no/such/input-file.png"])
    refute_equal 0, rc
    assert_match(/does not exist/, err)
  end

  def test_generate_width_zero_exits_nonzero
    rc, _out, err = run_cli(["generate", "synth/solid", "--width", "0"])
    assert_equal 2, rc
    assert_match(/positive integer/, err)
  end

  # --- generate --------------------------------------------------------------

  def test_generate_synth_solid

    Dir.mktmpdir do |dir|
      solid_png = File.join(dir, "solid.png")
      rc, out, err = run_cli(
        ["generate", "synth/solid", "--width", 4, "--height", 4, "--param", "color=#f30", "--filename", solid_png]
      )
      assert_equal 0, rc, "stdout=[#{out}] stderr=[#{err}]"
      assert_match(/^synth\/solid$/, out)
      assert_match(/Rendered 4x4 -> #{Regexp.escape(solid_png)}/, out)
      assert File.file?(solid_png)

      require_relative "../lib/noisemaker_cpu/png"
      surface = NoisemakerCpu::PNG.decode_png(File.binread(solid_png))
      assert_equal 4, surface.width
      assert_equal 4, surface.height
      px = surface.to_rgba8.unpack("C*")
      assert_equal [255, 51, 0, 255], px[0, 4]
    end
  end

  def test_generate_creates_missing_parent_dirs

    Dir.mktmpdir do |dir|
      nested = File.join(dir, "a", "b", "out.png")
      refute Dir.exist?(File.join(dir, "a"))
      rc, out, err = run_cli(["generate", "synth/solid", "--width", 4, "--height", 4, "--filename", nested])
      assert_equal 0, rc, "stdout=[#{out}] stderr=[#{err}]"
      assert File.file?(nested)
    end
  end

  # --- apply -------------------------------------------------------------

  def test_apply_filter_invert

    Dir.mktmpdir do |dir|
      solid_png = File.join(dir, "solid.png")
      run_cli(["generate", "synth/solid", "--width", 4, "--height", 4, "--param", "color=#f30", "--filename",
               solid_png])

      inverted_png = File.join(dir, "inverted.png")
      rc, out, err = run_cli(["apply", "filter/invert", solid_png, "--filename", inverted_png])
      assert_equal 0, rc, "stdout=[#{out}] stderr=[#{err}]"
      assert_match(%r{^filter/invert$}, out)
      assert_match(/Rendered 4x4 -> #{Regexp.escape(inverted_png)}/, out)

      require_relative "../lib/noisemaker_cpu/png"
      surface = NoisemakerCpu::PNG.decode_png(File.binread(inverted_png))
      assert_equal 4, surface.width
      assert_equal 4, surface.height
      px = surface.to_rgba8.unpack("C*")
      assert_equal [0, 204, 255], px[0, 3]
      assert_equal 255, px[3]
    end
  end

  # --- error paths -----------------------------------------------------------

  def test_generate_unknown_effect_exits_nonzero

    Dir.mktmpdir do |dir|
      filename = File.join(dir, "unknown-effect.png")
      rc, _out, err = run_cli(["generate", "bogus/nope", "--width", 4, "--height", 4, "--filename", filename])
      refute_equal 0, rc
      assert_match(/Unknown effect/, err)
      refute File.file?(filename)
    end
  end

  def test_generate_param_without_equals_exits_nonzero

    Dir.mktmpdir do |dir|
      filename = File.join(dir, "badparam.png")
      rc, _out, _err = run_cli(
        ["generate", "synth/solid", "--width", 4, "--height", 4, "--param", "badparam", "--filename", filename]
      )
      refute_equal 0, rc
      refute File.file?(filename)
    end
  end

  # --- random is partitioned by kind -----------------------------------------

  def test_generate_random_is_partitioned_by_kind

    Dir.mktmpdir do |dir|
      filename = File.join(dir, "random.png")
      rc, out, err = run_cli(["generate", "random", "--width", 4, "--height", 4, "--filename", filename])
      assert_equal 0, rc, "stdout=[#{out}] stderr=[#{err}]"

      echoed_id = out.lines.first&.chomp
      refute_nil echoed_id
      refute_empty echoed_id

      meta = JSON.parse(File.read(File.join(DIST_ROOT, "lib", "noisemaker_cpu", "bundle", "metadata.json")))
      assert meta["effects"].key?(echoed_id), "echoed id '#{echoed_id}' should be a known catalog effect"
      assert_equal "generator", meta["effects"][echoed_id]["kind"]
    end
  end

  # --- animate: ffmpeg absent -------------------------------------------------

  def test_animate_with_save_frames_exits_zero_even_without_ffmpeg

    Dir.mktmpdir do |dir|
      frames_dir = File.join(dir, "frames")
      rc, out, err = run_cli(
        ["animate", "synth/solid", "--width", 4, "--height", 4, "--frame-count", 2, "--save-frames", frames_dir],
        env: { "PATH" => "" }
      )
      assert_equal 0, rc, "stdout=[#{out}] stderr=[#{err}]"
      assert_match(/ffmpeg not found/, out)
      assert File.file?(File.join(frames_dir, "frame_0000.png"))
      assert File.file?(File.join(frames_dir, "frame_0001.png"))
    end
  end

  def test_animate_without_save_frames_and_no_ffmpeg_exits_nonzero

    Dir.mktmpdir do |dir|
      filename = File.join(dir, "no-ffmpeg.mp4")
      rc, _out, err = run_cli(
        ["animate", "synth/solid", "--width", 4, "--height", 4, "--frame-count", 2, "--filename", filename],
        env: { "PATH" => "" }
      )
      refute_equal 0, rc
      assert_match(/ffmpeg not found/, err)
    end
  end

  # --- run: DSL renderer -------------------------------------------------

  def test_run_reads_dsl_program_from_stdin

    Dir.mktmpdir do |dir|
      filename = File.join(dir, "run.png")
      rc, _out, err = run_cli(
        ["run", "--width", 4, "--height", 4, "--filename", filename],
        stdin: "search synth\nsolid(color: #336699).write(o0)\nrender(o0)\n"
      )
      assert_equal 0, rc, "stdout=[] stderr=[#{err}]"
      assert File.file?(filename)
    end
  end

  def test_run_with_input_and_texture_and_dsl_error

    Dir.mktmpdir do |dir|
      tex = File.join(dir, "tex.png")
      rc0, = run_cli(["generate", "synth/solid", "--width", 4, "--height", 4, "--param", "color=#4080c0",
                       "--filename", tex])
      assert_equal 0, rc0, "texture source should render"

      # media samples imageTex -- bound via --input
      out = File.join(dir, "media.png")
      rc1, _so1, se1 = run_cli(
        ["run", "--width", 4, "--height", 4, "--input", tex, "--filename", out],
        stdin: "search synth\nmedia(imageSize: [4, 4]).write(o0)\nrender(o0)\n"
      )
      assert_equal 0, rc1, "run --input binds imageTex: #{se1}"
      assert File.exist?(out) && !File.zero?(out), "run --input should write a png"

      # --texture NAME=FILE named binding
      out2 = File.join(dir, "media2.png")
      rc2, _so2, se2 = run_cli(
        ["run", "--width", 4, "--height", 4, "--texture", "imageTex=#{tex}", "--texture", "textTex=#{tex}",
         "--filename", out2],
        stdin: "search synth\nmedia(imageSize: [4, 4]).write(o0)\nrender(o0)\n"
      )
      assert_equal 0, rc2, "run --texture binds named samplers: #{se2}"

      # a DSL compile error surfaces cleanly with a nonzero exit
      rc3, _so3, se3 = run_cli(["run", "--width", 4, "--height", 4], stdin: "solid().write(o0)\nrender(o0)\n")
      refute_equal 0, rc3
      assert_match(/Missing required search directive/, se3)
    end
  end
end
