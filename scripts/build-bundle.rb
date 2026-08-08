#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require_relative "../lib/noisemaker_cpu/transpiler/build"

NoisemakerCpu::Transpiler::Build.run(*ARGV)
