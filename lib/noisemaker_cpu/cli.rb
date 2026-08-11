# frozen_string_literal: true

# noisemaker-rb -- render the Noisemaker shader catalog on the CPU.
#
# Faithful Ruby port of bin/make-noise (itself a Perl port of the
# noisemaker-py click CLI, noisemaker_cpu/cli.py): same subcommands
# (generate/apply/animate/run), option names, defaults, and output
# messages, ported as closely as Ruby's OptionParser allows. Renders a
# catalog effect by id (e.g. 'synth/curl', 'filter/chrome'); 'random' picks
# one at random, partitioned by kind (generators for generate/animate,
# filters for apply) so it never picks an effect that would render
# degenerately.
#
# Usage: noisemaker-rb COMMAND [OPTIONS] [ARGS]...

require "optparse"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

require_relative "version"
require_relative "png"
require_relative "renderer"

module NoisemakerCpu
  class CLI
    MAX_SEED_VALUE = (2**32) - 1

    # Getopt::Long's `=i`/`=f` accept an optionally-signed integer/float
    # *format* at parse time; Perl's own `_require_positive_int` re-checks
    # width/height/etc. against a *stricter* unsigned-digits-only pattern
    # afterward (so e.g. "+5" parses fine but is then rejected as "not a
    # positive integer"). These two constants exist only to reproduce that
    # first, permissive parse-time format check without Ruby's OptionParser
    # Integer/Float coercion types, which silently octal-decode a leading
    # zero (`Integer("010") == 8`) where Perl's `=i` stays decimal -- see
    # _to_int/_require_positive_int below for the second, stricter stage.
    INT_OPTION_RE = /\A[-+]?\d+\z/
    FLOAT_OPTION_RE = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/

    # Usage-class error: caught by `main` and reported with exit code 2.
    # Perl signals this with a "usage: " message prefix that `main` strips
    # before printing (stripped successfully => exit 2, otherwise exit 1);
    # every "usage: "-prefixed `die` in bin/make-noise originates in the
    # CLI layer itself (PNG/DSL/Renderer never raise one), so a dedicated
    # exception class here is behaviorally equivalent and avoids a
    # string-prefix sentinel Ruby has no real need for.
    class UsageError < StandardError; end

    COMMANDS = {
      "generate" => :cmd_generate,
      "apply" => :cmd_apply,
      "animate" => :cmd_animate,
      "run" => :cmd_run,
    }.freeze

    # ---------------------------------------------------------------------
    # Dispatch
    # ---------------------------------------------------------------------

    def self.main(argv)
      $stdout.sync = true
      argv = argv.dup

      if argv.empty? || argv[0] == "-h" || argv[0] == "--help"
        print usage
        return 0
      end
      if argv[0] == "--version"
        puts version_string
        return 0
      end

      command = argv.shift
      handler = COMMANDS[command]
      unless handler
        warn "Unknown command: '#{command}'. Choose from: generate, apply, animate, run."
        return 2
      end

      begin
        rc = send(handler, argv)
      rescue StandardError => e
        msg = e.message.dup
        msg << "\n" unless msg.end_with?("\n")
        usage_error = e.is_a?(UsageError)
        $stderr.print(msg)
        return usage_error ? 2 : 1
      end
      rc.nil? ? 0 : rc
    end

    def self.version_string
      "noisemaker-rb (NoisemakerCpu) #{NoisemakerCpu::VERSION}"
    end

    def self.usage
      <<~'USAGE'
        Usage: noisemaker-rb COMMAND [OPTIONS] [ARGS]...

          Noisemaker for Ruby -- render the Noisemaker shader catalog on the CPU.

          Renders a catalog effect by id (e.g. 'synth/curl', 'filter/chrome');
          'random' picks one at random. 'generate' takes no input and 'apply' takes
          the input image as a positional argument; 'random' is partitioned by kind
          (generators for generate/animate, filters for apply) so it never picks an
          effect that would render degenerately.

        Commands:
          generate EFFECT       Render a catalog effect to a .png
          apply EFFECT INPUT    Apply an effect to a .png image
          animate EFFECT        Render an effect over time to an animation (.mp4)
          run                   Render a Polymorphic DSL program read from STDIN

        Global options:
          -h, --help             Show this message and exit.
          --version               Show the version and exit.

        Options for generate EFFECT:
          --width INTEGER        Output width, in pixels [default: 1024]
          --height INTEGER       Output height, in pixels [default: 1024]
          --time FLOAT           Time value for the Z axis / animation phase [default: 0.0]
          --seed INTEGER         Random seed. Might not affect all effects.
          --filename PATH        Image output filename (.png) [default: art.png]
          --param NAME=VALUE     Effect parameter (repeatable)

        Options for apply EFFECT INPUT:
          --time FLOAT           Time value for the Z axis / animation phase [default: 0.0]
          --seed INTEGER         Random seed. Might not affect all effects.
          --filename PATH        Image output filename (.png) [default: mangled.png]
          --param NAME=VALUE     Effect parameter (repeatable)

        Options for animate EFFECT:
          --width INTEGER        Output width, in pixels [default: 512]
          --height INTEGER       Output height, in pixels [default: 512]
          --seed INTEGER         Random seed. Might not affect all effects.
          --filename PATH        Animation output filename (.mp4) [default: animation.mp4]
          --frame-count INTEGER  How many frames total [default: 50]
          --fps INTEGER          Frames per second for the encoded video [default: 30]
          --speed FLOAT          Time-sweep multiplier, loops of the [0,1) time phase [default: 1.0]
          --save-frames DIR      Directory to also write the PNG frames into
          --param NAME=VALUE     Effect parameter (repeatable)

        Options for run (reads a DSL program from STDIN):
          --width INTEGER        Output width, in pixels [default: 512]
          --height INTEGER       Output height, in pixels [default: 512]
          --time FLOAT           Time value for the Z axis / animation phase [default: 0.0]
          --seed INTEGER         Deterministic render seed threaded into effect seed params [default: 1]
          --filename PATH        Image output filename (.png) [default: art.png]
          --input FILE           PNG bound as imageTex and textTex
          --texture NAME=FILE    External PNG texture (repeatable)

        EFFECT may be 'random' or a catalog id like 'synth/curl'.
        Run 'noisemaker-rb COMMAND --help' for this same reference.
      USAGE
    end

    # ---------------------------------------------------------------------
    # Commands
    # ---------------------------------------------------------------------

    def self.cmd_generate(argv)
      width_s = "1024"
      height_s = "1024"
      time_s = "0.0"
      seed_s = nil
      filename = "art.png"
      params = []
      help = false

      parser = OptionParser.new do |opts|
        opts.on("--width WIDTH", INT_OPTION_RE) { |v| width_s = v }
        opts.on("--height HEIGHT", INT_OPTION_RE) { |v| height_s = v }
        opts.on("--time TIME", FLOAT_OPTION_RE) { |v| time_s = v }
        opts.on("--seed SEED", INT_OPTION_RE) { |v| seed_s = v }
        opts.on("--filename FILENAME") { |v| filename = v }
        opts.on("--param NAME=VALUE") { |v| params << v }
        opts.on("-h", "--help") { help = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        return 2
      end
      if help
        print usage
        return 0
      end

      width = _require_positive_int(width_s, "width")
      height = _require_positive_int(height_s, "height")

      effect = argv.shift
      raise UsageError, "usage: Missing argument 'EFFECT'.\n" if effect.nil?

      _no_extra_args(argv)

      time_value = Float(time_s)
      seed = seed_s.nil? ? nil : _to_int(seed_s)

      effect, seed = _prologue(effect, seed, "generator")
      surface = _render_cli_effect(
        effect, _parse_params(params),
        width: width, height: height, seed: seed, time: time_value
      )
      _write_png(surface, filename)
      puts "Rendered #{width}x#{height} -> #{filename}"
      0
    end

    def self.cmd_apply(argv)
      time_s = "0.0"
      seed_s = nil
      filename = "mangled.png"
      params = []
      help = false

      parser = OptionParser.new do |opts|
        opts.on("--time TIME", FLOAT_OPTION_RE) { |v| time_s = v }
        opts.on("--seed SEED", INT_OPTION_RE) { |v| seed_s = v }
        opts.on("--filename FILENAME") { |v| filename = v }
        opts.on("--param NAME=VALUE") { |v| params << v }
        opts.on("-h", "--help") { help = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        return 2
      end
      if help
        print usage
        return 0
      end

      effect = argv.shift
      raise UsageError, "usage: Missing argument 'EFFECT'.\n" if effect.nil?

      input_filename = argv.shift
      raise UsageError, "usage: Missing argument 'INPUT_FILENAME'.\n" if input_filename.nil?

      _no_extra_args(argv)
      unless File.exist?(input_filename) && !File.directory?(input_filename)
        raise "Invalid value for 'INPUT_FILENAME': Path '#{input_filename}' does not exist.\n"
      end

      time_value = Float(time_s)
      seed = seed_s.nil? ? nil : _to_int(seed_s)

      effect, seed = _prologue(effect, seed, "filter")
      domain = Renderer.meta["effects"][effect]["domain"] || "image"
      if domain != "image"
        raise "apply only supports image-domain effects; use run with a typed DSL chain for #{domain} effects\n"
      end
      source = _load_png(input_filename)
      surface = Renderer.render_effect(
        effect, _parse_params(params), _bind_input(effect, source),
        width: source.width, height: source.height, seed: seed, time: time_value
      )
      _write_png(surface, filename)
      puts "Rendered #{source.width}x#{source.height} -> #{filename}"
      0
    end

    def self.cmd_animate(argv)
      width_s = "512"
      height_s = "512"
      seed_s = nil
      filename = "animation.mp4"
      frame_count_s = "50"
      fps_s = "30"
      speed_s = "1.0"
      save_frames = nil
      params = []
      help = false

      parser = OptionParser.new do |opts|
        opts.on("--width WIDTH", INT_OPTION_RE) { |v| width_s = v }
        opts.on("--height HEIGHT", INT_OPTION_RE) { |v| height_s = v }
        opts.on("--seed SEED", INT_OPTION_RE) { |v| seed_s = v }
        opts.on("--filename FILENAME") { |v| filename = v }
        opts.on("--frame-count COUNT", INT_OPTION_RE) { |v| frame_count_s = v }
        opts.on("--fps FPS", INT_OPTION_RE) { |v| fps_s = v }
        opts.on("--speed SPEED", FLOAT_OPTION_RE) { |v| speed_s = v }
        opts.on("--save-frames DIR") { |v| save_frames = v }
        opts.on("--param NAME=VALUE") { |v| params << v }
        opts.on("-h", "--help") { help = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        return 2
      end
      if help
        print usage
        return 0
      end

      width = _require_positive_int(width_s, "width")
      height = _require_positive_int(height_s, "height")
      frame_count = _require_positive_int(frame_count_s, "frame-count")
      fps = _require_positive_int(fps_s, "fps")

      effect = argv.shift
      raise UsageError, "usage: Missing argument 'EFFECT'.\n" if effect.nil?

      _no_extra_args(argv)

      speed = Float(speed_s)
      seed = seed_s.nil? ? nil : _to_int(seed_s)

      effect, seed = _prologue(effect, seed, "generator")
      parsed = _parse_params(params)

      # Cleaned up in `ensure` (even on raise) unless --save-frames was
      # given, mirroring Perl's File::Temp::Dir auto-cleanup-on-scope-exit
      # (which fires during eval-caught stack unwinding too).
      tempdir = nil
      frames_dir = save_frames
      if frames_dir.nil?
        tempdir = Dir.mktmpdir("noisemaker-rb-")
        frames_dir = tempdir
      end

      begin
        FileUtils.mkdir_p(frames_dir)

        (0...frame_count).each do |i|
          time_value = i.fdiv(frame_count) * speed # sweep [0,1) phase, `speed` loops
          surface = _render_cli_effect(
            effect, parsed,
            width: width, height: height, seed: seed, time: time_value
          )
          _write_png(surface, File.join(frames_dir, format("frame_%04d.png", i)))
        end

        ffmpeg = _which("ffmpeg")
        if ffmpeg.nil?
          if save_frames
            puts "ffmpeg not found; wrote #{frame_count} frames to #{frames_dir} (no video)."
            return 0
          end
          raise "ffmpeg not found; install it, or pass --save-frames DIR to keep the PNG frames.\n"
        end

        cmd = [
          ffmpeg, "-y",
          "-framerate", fps.to_s,
          "-i", File.join(frames_dir, "frame_%04d.png"),
          "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
          "-c:v", "libx264",
          "-pix_fmt", "yuv420p",
          filename,
        ]
        _stdout_str, stderr_str, status =
          begin
            Open3.capture3(*cmd)
          rescue SystemCallError => e
            raise "ffmpeg failed to execute: #{e.message}\n"
          end
        raise "ffmpeg was killed by signal #{status.termsig}\n" if status.signaled?

        if status.exitstatus != 0
          tail = _tail_lines(stderr_str, 5)
          raise "ffmpeg failed:\n#{tail.join("\n")}\n"
        end
        puts "Rendered #{frame_count} frames (#{width}x#{height}) -> #{filename}"
        0
      ensure
        FileUtils.remove_entry(tempdir) if tempdir && File.directory?(tempdir)
      end
    end

    def self.cmd_run(argv)
      width_s = "512"
      height_s = "512"
      time_s = "0.0"
      seed_s = "1"
      filename = "art.png"
      input_filename = nil
      textures = []
      help = false

      parser = OptionParser.new do |opts|
        opts.on("--width WIDTH", INT_OPTION_RE) { |v| width_s = v }
        opts.on("--height HEIGHT", INT_OPTION_RE) { |v| height_s = v }
        opts.on("--time TIME", FLOAT_OPTION_RE) { |v| time_s = v }
        opts.on("--seed SEED", INT_OPTION_RE) { |v| seed_s = v }
        opts.on("--filename FILENAME") { |v| filename = v }
        opts.on("--input FILE") { |v| input_filename = v }
        opts.on("--texture NAME=FILE") { |v| textures << v }
        opts.on("-h", "--help") { help = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        return 2
      end
      if help
        print usage
        return 0
      end

      width = _require_positive_int(width_s, "width")
      height = _require_positive_int(height_s, "height")
      _no_extra_args(argv)

      if input_filename && !(File.exist?(input_filename) && !File.directory?(input_filename))
        raise "Invalid value for '--input': Path '#{input_filename}' does not exist.\n"
      end

      time_value = Float(time_s)
      seed = _to_int(seed_s)

      source_program = $stdin.read
      source_program = "" if source_program.nil?

      # Build the DSL's external-texture map: --input binds one PNG as both
      # imageTex and textTex (mirroring the JS CLI); --texture NAME=FILE
      # binds a named sampler (repeatable).
      external = {}
      if input_filename
        surface = _load_png(input_filename)
        external["imageTex"] = surface
        external["textTex"] = surface
      end
      textures.each do |pair|
        idx = pair.index("=")
        raise UsageError, "usage: Expected NAME=FILE, received '#{pair}'\n" if idx.nil?

        name = pair[0, idx]
        path = pair[(idx + 1)..]
        raise UsageError, "usage: Expected NAME=FILE, received '#{pair}'\n" if name.empty? || path.empty?
        raise "No such texture file: #{path}\n" unless File.file?(path)

        external[name] = _load_png(path)
      end

      unless Renderer.respond_to?(:render_dsl)
        raise "render_dsl is not available in NoisemakerCpu::Renderer yet.\n"
      end

      surface = Renderer.render_dsl(
        source_program,
        width: width, height: height, seed: seed, time: time_value, external_textures: external
      )
      _write_png(surface, filename)
      puts "Rendered #{surface.width}x#{surface.height} -> #{filename}"
      0
    end

    # ---------------------------------------------------------------------
    # Shared helpers (ported from noisemaker_cpu/cli.py / bin/make-noise)
    # ---------------------------------------------------------------------

    # Resolve an EFFECT argument to a catalog id. `random` picks from
    # image-domain effects of the given `kind` ("generator"/"filter"); an
    # explicit id is used as-is.
    def self._resolve_effect(effect, kind)
      effects = Renderer.meta["effects"]
      if effect == "random"
        pool = effects.keys.select do |key|
          candidate = effects[key]
          (kind.nil? || (candidate["kind"] || "") == kind) &&
            (candidate["domain"] || "image") == "image" &&
            !candidate["iterated"] && candidate["externalTexture"].nil?
        end.sort
        raise UsageError, "usage: No #{kind} effects available.\n" if pool.empty?

        return pool[rand(pool.length)]
      end
      unless effects.key?(effect)
        raise UsageError, "usage: Unknown effect: #{effect}. Pass 'random' or a catalog id like 'synth/curl'.\n"
      end

      effect
    end

    # Shared command entry: resolve the effect, default the seed, echo the id.
    def self._prologue(effect, seed, kind)
      effect = _resolve_effect(effect, kind)
      seed = 1 + rand(MAX_SEED_VALUE) if seed.nil?
      puts effect
      [effect, seed]
    end

    def self._parse_params(pairs)
      params = {}
      pairs.each do |kv|
        idx = kv.index("=")
        raise UsageError, "usage: Expected NAME=VALUE, received '#{kv}'\n" if idx.nil?

        params[kv[0, idx]] = kv[(idx + 1)..]
      end
      params
    end

    def self._dsl_value(value)
      text = value.to_s
      return text if text.match?(/\A(?:
        -?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?
        |true|false|\#[0-9A-Fa-f]{3,8}
        |[A-Za-z_][A-Za-z0-9_.]*
        |\[.*\]
      )\z/x)

      JSON.generate(text)
    end

    def self._typed_effect_program(effect_id, params)
      effect = Renderer.meta["effects"][effect_id]
      args = params.keys.sort.map { |name| "#{name}: #{_dsl_value(params[name])}" }.join(", ")
      call = "#{effect['func']}(#{args})"
      domain = effect["domain"] || "image"
      if domain == "loop-begin" || domain == "loop-end"
        loop_begin = domain == "loop-begin" ? call : "loopBegin(iterationCount: 1)"
        loop_end = domain == "loop-end" ? call : "loopEnd()"
        return "search render, synth\nsolid().#{loop_begin}.#{loop_end}.write(o0)\nrender(o0)"
      end

      supplied_size = params["volumeSize"]
      size_spec = (effect["params"] || {})["volumeSize"] || {}
      volume_size = supplied_size.nil? ? (size_spec["default"] || 16) : supplied_size
      unless volume_size.to_s.match?(/\A\d+(?:\.\d+)?\z/)
        choice = volume_size.to_s.split(".").last
        volume_size = (size_spec["choices"] || {})[choice] || size_spec["default"] || 16
      end
      search = "search synth3d, filter3d, render"
      return "#{search}\n#{call}.render3d().write(o0)\nrender(o0)" if domain == "volume-generator"
      if domain == "volume-filter"
        return "#{search}\nnoise3d(volumeSize: #{volume_size}).#{call}.render3d().write(o0)\nrender(o0)"
      end

      "#{search}\nnoise3d(volumeSize: #{volume_size}).#{call}.write(o0)\nrender(o0)"
    end

    def self._render_cli_effect(effect_id, params, **options)
      domain = Renderer.meta["effects"][effect_id]["domain"] || "image"
      return Renderer.render_effect(effect_id, params, nil, **options) if domain == "image"

      Renderer.render_dsl(_typed_effect_program(effect_id, params), **options)
    end

    # An effect that reads a host texture (filter/text, synth/media) binds
    # the same image, mirroring the noisemaker/js CLI's input (imageTex +
    # textTex).
    def self._bind_input(effect_id, surface)
      inputs = { "inputTex" => surface }
      external = Renderer.meta["effects"][effect_id]["externalTexture"]
      inputs[external] = surface if external
      inputs
    end

    def self._write_png(surface, filename)
      dir = File.dirname(filename)
      FileUtils.mkdir_p(dir) unless dir.empty? || dir == "."
      File.open(filename, "wb") { |fh| fh.write(PNG.encode_png(surface)) }
    end

    def self._load_png(path)
      PNG.decode_png(File.binread(path))
    end

    # Perl's Getopt::Long `=i` type accepts a signed integer at parse time
    # (see INT_OPTION_RE); `_require_positive_int` then re-validates with
    # Perl's own stricter `/^\d+$/` (no sign) before requiring > 0.
    def self._require_positive_int(raw, opt_name)
      ok = !raw.nil? && raw.match?(/\A\d+\z/) && Integer(raw, 10) > 0
      raise UsageError, "usage: --#{opt_name} must be a positive integer\n" unless ok

      Integer(raw, 10)
    end

    # Decimal-only integer conversion for fields Getopt::Long's `=i` accepts
    # without Perl's extra positivity check (--seed): Ruby's Integer(str)
    # would otherwise octal-decode a leading zero.
    def self._to_int(str)
      Integer(str, 10)
    end

    def self._no_extra_args(argv)
      return if argv.empty?

      raise "Got unexpected extra argument#{argv.length > 1 ? 's' : ''} (#{argv.join(' ')})\n"
    end

    # `which`-style PATH scan (stdlib File only; no shelling out to `which`).
    def self._which(prog)
      dirs = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
      dirs.each do |dir|
        candidate = File.join(dir, prog)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def self._tail_lines(text, n)
      return [] if text.nil? || text.empty?

      lines = text.split("\n")
      return lines if lines.length <= n

      lines[-n..]
    end
  end
end
