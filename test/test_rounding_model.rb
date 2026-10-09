# frozen_string_literal: true

# The shared rounding-model contract, settled against the pinned CPU
# authority's own transpilation (noisemaker-for-perl t/25-rounding-model.t
# and the same t/data/rounding-model.json fixture, captured from the
# oracle at the recorded revision). Every case transpiles a small GLSL
# shader with THIS port's codegen, runs the emitted kernel through the
# real Runtime, and compares f32 output BITS against the oracle's
# recorded rows — pinning where the compiled JS rounds to f32:
# inline pooled-array constructors round once at the store, vecN.op
# calls round per operation, Float32Array#map rounds, plain-Array maps
# stay raw, and distance rounds each difference and the dot product.

require "json"
require "minitest/autorun"
require_relative "../lib/noisemaker_cpu"
require_relative "../lib/noisemaker_cpu/transpiler/shared_enums"
require_relative "../lib/noisemaker_cpu/transpiler/computed_defs"
require_relative "../lib/noisemaker_cpu/transpiler/lexer"
require_relative "../lib/noisemaker_cpu/transpiler/preprocess"
require_relative "../lib/noisemaker_cpu/transpiler/parser"
require_relative "../lib/noisemaker_cpu/transpiler/codegen"

class TestRoundingModel < Minitest::Test
  FIXTURE_PATH = File.expand_path("fixtures/rounding-model.json", __dir__)
  FIXTURE = JSON.parse(File.binread(FIXTURE_PATH))
  PT = NoisemakerCpu::Transpiler

  def test_fixture_covers_every_case_bit_exact
    rt = NoisemakerCpu::Runtime.new
    failures = []

    FIXTURE["cases"].each_with_index do |case_row, case_idx|
      norm = PT::Preprocess.normalize(case_row["shader"], {})
      ast = PT::Parser.parse(norm["source"])
      src = PT::Codegen.emit_ruby(ast, norm["outputs"], norm["varyings"])
      result = eval(src, TOPLEVEL_BINDING.dup, "rounding-model:#{case_idx}") # rubocop:disable Security/Eval
      got = FIXTURE["inputs"].map do |u|
        uniforms = {}
        u.each { |k, v| uniforms[k] = v.is_a?(Array) ? v.dup : v }
        ctx = NoisemakerCpu::Ctx.new(rt: rt, uniforms: uniforms, textures: {},
                                     resolution: [1, 1], time: 0.0, seed: 1,
                                     blank: NoisemakerCpu::Surface.new(1, 1))
        out = [0.0, 0.0, 0.0, 0.0]
        result[:kernel].call(ctx, out)
        out.first(3).map { |v| [v].pack("e").unpack1("L") }
      end
      next if got == case_row["expected"]

      bad_rows = got.each_index.select { |i| got[i] != case_row["expected"][i] }
      failures << { label: case_row["label"], rows: bad_rows,
                    got: bad_rows.map { |i| got[i] },
                    expected: bad_rows.map { |i| case_row["expected"][i] } }
    end

    assert failures.empty?,
           "ROUNDING-MODEL #{FIXTURE['cases'].length - failures.length}/" \
           "#{FIXTURE['cases'].length} bit-exact; failing rows: " \
           "#{JSON.generate(failures)}"
  end
end
