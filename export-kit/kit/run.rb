#!/usr/bin/env ruby
# frozen_string_literal: true

# Render this export's program on the CPU and write a PNG.
#
# Puts the vendored port in `engine/lib` on the load path and calls it
# directly, so nothing has to be installed: this file plus `engine/` is the
# whole program. `NoisemakerCpu::Renderer.render_dsl` compiles the DSL and
# evaluates it pixel by pixel; `NoisemakerCpu::PNG.encode_png` turns the
# resulting surface into bytes.

require "optparse"

$LOAD_PATH.unshift(File.expand_path("engine/lib", __dir__))
require "noisemaker_cpu"

options = { width: 512, height: 512, seed: 1, time: 0.0, output: "art.png" }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby run.rb [PROGRAM.dsl] [options]"
  opts.on("--width N", Integer, "output width in pixels (default: 512)") { |v| options[:width] = v }
  opts.on("--height N", Integer, "output height in pixels (default: 512)") { |v| options[:height] = v }
  opts.on("--seed N", Integer, "deterministic seed (default: 1)") { |v| options[:seed] = v }
  opts.on("--time N", Float, "normalized time (default: 0.0)") { |v| options[:time] = v }
  opts.on("--output FILE", "PNG to write (default: art.png)") { |v| options[:output] = v }
  opts.on("-h", "--help", "show this message") do
    puts opts
    exit 0
  end
end.parse!(ARGV)

program = ARGV.shift || "program.dsl"
source = begin
  File.read(program, encoding: "UTF-8")
rescue SystemCallError => e
  # The likeliest mistake by far, since every documented invocation names the
  # program as a bare relative path. One line beats a backtrace. Errno messages
  # carry a " @ rb_sysopen - <path>" tail that only repeats the path.
  abort "cannot read #{program}: #{e.message.split(' @ ').first}"
end

surface = NoisemakerCpu::Renderer.render_dsl(
  source,
  width: options[:width],
  height: options[:height],
  seed: options[:seed],
  time: options[:time]
)

File.binwrite(options[:output], NoisemakerCpu::PNG.encode_png(surface))
puts "Rendered #{surface.width}x#{surface.height} -> #{options[:output]}"
