# frozen_string_literal: true

require_relative "lib/noisemaker_cpu/version"

Gem::Specification.new do |spec|
  spec.name = "noisemaker-for-ruby"
  spec.version = NoisemakerCpu::VERSION
  spec.authors = ["Noise Factor LLC"]
  spec.summary = "CPU Noisemaker shader engine — Ruby port of noisemaker-cpu (GLSL-transpiled)"
  spec.description = "Pure-Ruby CPU implementation of the Noisemaker shader engine: " \
                     "the 205-effect catalog transpiled from the shaders.noisedeck.app CDN, " \
                     "rendered at byte-parity with the reference JavaScript engine."
  spec.homepage = "https://github.com/noisefactorllc/noisemaker-for-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.read.split("\x0").reject { |f| f.start_with?("docs/", "test/", "scripts/", ".") }
  end
  spec.bindir = "exe"
  spec.executables = ["noisemaker-rb"]
  spec.require_paths = ["lib"]
end
