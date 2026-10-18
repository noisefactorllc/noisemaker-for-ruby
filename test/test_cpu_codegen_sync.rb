# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/transpiler/preprocess"
require_relative "../lib/noisemaker_cpu/transpiler/parser"
require_relative "../lib/noisemaker_cpu/transpiler/codegen"
require_relative "../lib/noisemaker_cpu/pass_runner"

class TestCpuCodegenSync < Minitest::Test
  def compile(source, **options)
    norm = NoisemakerCpu::Transpiler::Preprocess.normalize(source, {})
    NoisemakerCpu::Transpiler::Codegen.emit_ruby(
      NoisemakerCpu::Transpiler::Parser.parse(norm["source"]), norm["outputs"], norm["varyings"],
      "filter/spookyTicker", **options
    )
  end

  def render(source, uniforms = {}, **options)
    kernel = eval(compile(source, **options), binding, "cpu-sync-probe")[:kernel]
    ctx = NoisemakerCpu::Ctx.new(rt: NoisemakerCpu::Runtime.new, uniforms: uniforms)
    NoisemakerCpu::PassRunner.run_pass(kernel, ctx, 1, 1).data
  end

  def bits(values)
    values.pack("e*").unpack("L<*")
  end

  def test_runtime_division_and_folded_helper_keep_distinct_bits
    shader = <<~GLSL
      uniform float width;
      out vec4 fragColor;
      float helper(float x, float divisor) { return x / divisor; }
      void main() {
        float localWidth = width + 0.0;
        const float folded = 41.0;
        fragColor = vec4(1.0 / width, 1.0 / localWidth, 1.0 / folded, helper(1.0, 41.0));
      }
    GLSL
    assert_equal [1019727373, 1019727373, 1019727372, 1019727372], bits(render(shader, {"width" => 41.0}))
  end

  def test_runtime_define_divisor_keeps_folded_division
    shader = "uniform float WIDTH; out vec4 fragColor; void main() { fragColor=vec4(1.0/WIDTH); }"
    assert_equal [1019727372] * 4, bits(render(shader, {"WIDTH" => 41.0}, constant_divisors: {"WIDTH" => 41}))
  end

  def test_vector_compound_division_keeps_scalar_and_indexed_division_raw
    shader = <<~GLSL
      uniform float width;
      out vec4 fragColor;
      void main() {
        vec2 p=vec2(1.0,3.0); p /= width;
        float x=1.0; x /= width;
        vec2 q=vec2(1.0); q[0] /= width;
        fragColor=vec4(p,x,q[0]);
      }
    GLSL
    assert_equal [1019727373, 1033230986, 1019727372, 1019727372], bits(render(shader, {"width" => 41.0}))
  end

  def test_compound_division_respects_cpu_target_and_divisor_shapes
    [
      ["vec2 p[1]; p[0]=vec2(1.0); p[0]/=width; fragColor=vec4(p[0],0.0,0.0);", [1019727373,1019727373,0,0]],
      ["vec4 p=vec4(1.0); p.xy/=vec2(width); fragColor=p;", [1019727373,1019727373,1065353216,1065353216]],
      ["vec2 p=vec2(1.0); p/=dims; fragColor=vec4(p,0.0,0.0);", [1019727372,1019727372,0,0]],
    ].each do |body, expected|
      source = "uniform float width; uniform vec2 dims; out vec4 fragColor; void main(){#{body}}"
      assert_equal expected, bits(render(source, {"width"=>41.0,"dims"=>[41.0,41.0]})), body
    end
  end

  def test_staged_assignment_expression_returns_the_vector
    shader = "out vec4 fragColor; void main(){vec2 p=vec2(1.0,2.0); vec2 q=(p=vec2(p.y,-p.x)); fragColor=vec4(p,q);}"
    assert_equal [2.0,-1.0,2.0,-1.0], render(shader)
  end

  def test_integer_vector_cast_and_scalar_splat_keep_cpu_type_evidence
    shader = <<~GLSL
      uniform ivec2 dims; uniform ivec2 xy; uniform int x; out vec4 fragColor;
      void main() { vec2 a=vec2(xy)/vec2(dims); vec2 b=vec2(x)/vec2(dims); fragColor=vec4(a,b); }
    GLSL
    assert_equal [1019727372, 1019727372, 1019727373, 1019727373], bits(render(shader, {"dims" => [41,41], "xy" => [1,1], "x" => 1}))
  end

  def test_whole_vector_writes_stage_self_reads_and_preserve_aliases
    [
      ["p=vec2(dot(p,vec2(2.0,0.0)),dot(p,vec2(3.0,0.0)));", [2,3]],
      ["p=vec2(p.y,\n-p.x);", [2,-1]],
      ["p=vec2(p.t,p.s);", [2,1]],
      ["p=vec2(p.y,p[0x0]);", [2,1]],
      ["p=vec2(p.y,p[0u]);", [2,1]],
      ["p=dot(p,vec2(2.0,3.0))*vec2(2.0,3.0);", [16,24]],
      ["p=vec2(p.x-2.0*p.y,-2.0*p.x-p.y)/2.0;", [-1.5,-2]],
      ["p*=p;", [1,4]],
    ].each do |assignment, expected|
      shader = "out vec4 fragColor; void main(){vec2 p=vec2(1.0,2.0), alias=p; #{assignment} fragColor=vec4(p,alias);}"
      assert_equal (expected + expected).map(&:to_f), render(shader), assignment
    end
  end

  def test_scalar_and_ternary_int_divisions_match_cpu_statement_rewrites
    [
      ["a/CW", 0],
      ["a>0 ? a/CW : (a-CW+1)/CW", 0],
      ["a>0 ? (-a)/CW : (-b)/CW", -0.0],
      ["a>0 ? (a*(b+1))/CW : ((a+b)*2)/CW", 2.0/3],
      ["a>0 ? (abs(a)+b)/CW : (abs(b)+a)/CW", 2.0/3],
    ].each do |expression, expected|
      shader = "uniform int a; uniform int b; uniform int CW; out vec4 fragColor; void main(){int x=#{expression}; fragColor=vec4(float(x));}"
      assert_equal bits([expected]*4), bits(render(shader, {"a"=>1, "b"=>1, "CW"=>3})), expression
    end
  end

  def test_grouped_integer_operands_keep_cpu_float_evidence
    [["int x=(a)/CW",1019727373], ["float x=1/(CW)",1019727373],
     ["int x=((a))/CW",1019727372], ["float x=1/((CW))",1019727372],
     ["int x=(float(a))/CW",1019727372]].each do |declaration, expected|
      shader = "uniform int a; uniform int CW; out vec4 fragColor; void main(){#{declaration}; fragColor=vec4(float(x));}"
      assert_equal [expected]*4, bits(render(shader, {"a"=>1,"CW"=>41})), declaration
    end
  end

  def test_ternary_integer_casts_remove_call_parentheses_before_rewrite
    shader = "uniform int a; uniform int b; uniform int CW; out vec4 fragColor; void main(){int x=a>0?(a+int(b))/CW:(b+int(a))/CW; fragColor=vec4(float(x));}"
    assert_equal [0]*4, bits(render(shader, {"a"=>1,"b"=>1,"CW"=>3}))
  end

  def test_ternary_integer_rewrite_uses_lowered_cast_and_group_shapes
    [
      ["a>0 ? (a)/CW : (b)/CW", 1019727373],
      ["a>0 ? (a+float(b))/CW : (b+float(a))/CW", 1028115980],
      ["a>0 ? ((a))/CW : ((b))/CW", 1019727372],
    ].each do |expression, expected|
      shader = "uniform int a; uniform int b; uniform int CW; out vec4 fragColor; void main(){int x=#{expression}; fragColor=vec4(float(x));}"
      assert_equal [expected]*4, bits(render(shader, {"a"=>1,"b"=>1,"CW"=>41})), expression
    end
  end

  def test_exact_murmur_body_routes_independent_of_name
    body = "v = v ^ (v >> 16u); v = v * 0x7feb352du; v = v ^ (v >> 15u); v = v * 0x846ca68bu; v = v ^ (v >> 16u); return v;"
    shader = "uint hash_mix(uint v){#{body}} out vec4 fragColor; void main(){fragColor=vec4(float(hash_mix(0xfedcba98u)));}"
    assert_equal bits([3080438707.0]*4), bits(render(shader))
    mutated = shader.sub("hash_mix", "hash_uint").sub("hash_mix", "hash_uint").sub("v >> 15u", "v >> 14u")
    refute_includes compile(mutated), "rt.hash_uint("
  end
end
