# frozen_string_literal: true

require "json"
require "open3"

module NoisemakerOracle
  LOCK = JSON.parse(File.read(File.join(__dir__, "oracle-lock.json"), encoding: "UTF-8")).freeze
  ROOT = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path("../../noisemaker-for-cpu", __dir__)
  CLI = File.join(ROOT, "bin", "noisemaker-cpu.js")

  def self.verify!
    raise "JavaScript oracle missing; set NOISEMAKER_CPU_DIR to the pinned checkout" unless File.file?(CLI)
    revision, error, status = Open3.capture3("git", "-C", ROOT, "rev-parse", "HEAD")
    unless status.success? && revision.strip == LOCK.fetch("revision")
      raise "JavaScript oracle must be #{LOCK['revision']}; received #{revision.strip}: #{error.strip}"
    end
    _, _, clean = Open3.capture3("git", "-C", ROOT, "diff", "--quiet", "HEAD", "--")
    raise "JavaScript oracle has modified tracked files" unless clean.success?
    raise "Node.js is required for parity tests" unless system("node", "--version", out: File::NULL, err: File::NULL)
    true
  end

  module Tests
    def require_oracle
      NoisemakerOracle.verify!
    rescue StandardError => error
      flunk error.message if ENV["NOISEMAKER_REQUIRE_ORACLE"] == "1"
      skip error.message
    end
  end

  # Both engines receive this exact scene. The reference `effect` CLI inserts
  # an emitter for particle consumers; comparing it to a bare Ruby effect
  # otherwise compares different inputs and different iteration counts.
  def self.particle_program(effect, params)
    written = []
    needs_emitter = effect.fetch("passes").any? do |pass|
      needs = (pass["inputs"] || {}).values.any? do |name|
        name.match?(/\Aglobal_(xyz|vel|rgba|points_trail)\z/) && !written.include?(name)
      end
      written.concat((pass["outputs"] || {}).values)
      needs
    end
    return nil unless needs_emitter

    args = params.map { |name, value| "#{name}: #{value}" }.join(", ")
    "search points, render, synth\n" \
      "solid().pointsEmit(stateSize: x64, iterationCount: 1).#{effect.fetch('func')}(#{args}).write(o0)\nrender(o0)"
  end
end
