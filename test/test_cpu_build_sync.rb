# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/transpiler/build"
require_relative "../lib/noisemaker_cpu/pass_runner"

class TestCpuBuildSync < Minitest::Test
  Build = NoisemakerCpu::Transpiler::Build
  Transpiler = NoisemakerCpu::Transpiler

  def render_probe(effect, program, source, uniforms = {})
    adapted = Build._adapt_source(effect, program, source)
    normalized = Transpiler::Preprocess.normalize(adapted)
    generated = Transpiler::Codegen.emit_ruby(
      Transpiler::Parser.parse(normalized["source"]), normalized["outputs"], normalized["varyings"], effect
    )
    kernel = NoisemakerCpu::KernelCache.load_kernel(generated)[:kernel]
    context = NoisemakerCpu::Ctx.new(rt: NoisemakerCpu::Runtime.new, uniforms: uniforms)
    NoisemakerCpu::PassRunner.run_pass(kernel, context, 1, 1).data
  end

  def test_scatter_rounds_seed_before_the_coordinate_add
    source = <<~GLSL
      uniform int seed;
      out vec4 fragColor;
      vec2 hash22(vec2 p) {
          return p;
      }
      void main() {
          vec2 hashCoord = vec2(512.5, 15.5);
          vec2 rnd = hash22(hashCoord + float(seed) * 101.7);
          fragColor = vec4(rnd, 0.0, 1.0);
      }
    GLSL
    assert_equal [1224.39990234375, 727.3999633789062, 0.0, 1.0],
                 render_probe("filter/scatter", "scatterJitter", source, "seed" => 7)
  end

  def test_navier_stokes_hash_rounds_before_fract
    source = <<~GLSL
      uniform float x;
      out vec4 fragColor;
      float hash11(float x) {
          return fract(sin(x * 12.9898) * 43758.5453);
      }
      void main() { fragColor = vec4(hash11(x)); }
    GLSL
    assert_equal [0.484375] * 4, render_probe("synth/navierStokes", "nsSplat", source, "x" => 31.37)
  end

  def test_mirror_wrap_retains_small_coordinates
    source = <<~GLSL
      uniform float x;
      out vec4 fragColor;
      void main() { fragColor = vec4(mod(x + 1.0, 2.0) - 1.0); }
    GLSL
    expected = [1.0e-8].pack("e").unpack1("e")
    assert_equal [expected] * 4, render_probe("filter/reverb", "reverb", source, "x" => 1.0e-8)
  end

  def test_extrude_odd_center_face_test_uses_center_relative_coordinates
    source = <<~GLSL
      uniform float h;
      uniform float depth;
      out vec4 fragColor;
      void main() {
          vec2 P = vec2(20.5);
          vec2 imgCenter = vec2(20.5);
          vec2 cellC = vec2(20.0);
          vec2 faceHalf = vec2(0.5000001);
          float s = 1.0 + h * (depth / 100.0) * 0.4;
          vec2 faceCenter = imgCenter + (cellC - imgCenter) * s;
          bool topHit = all(lessThanEqual(abs(P - faceCenter), faceHalf));
          fragColor = vec4(topHit ? 1.0 : 0.0);
      }
    GLSL
    assert_equal [0.0] * 4, render_probe("filter/extrude", "extrude", source, "h" => 1.0e-6, "depth" => 100.0)
  end

  def lattice_source(width)
    type = "vec#{width}"
    hash = "hash#{width}"
    grad = "grad#{width}"
    axes = "xyzw".chars.first(width)
    coordinate = width == 4 ? "vec4 ps = p + float(seed) * 0.1;" : "// Add seed to input to vary the noise pattern\n    p = p + float(seed) * 0.1;"
    points = width == 4 ? "ps" : "p"
    mixes = axes.each_index.map { |i| "q.#{axes[i]} += q.#{axes[(i + 1) % width]} * q.#{axes[(i + 2) % width]};" }.join("\n")
    hashes = ["float h1 = #{hash}(p);", "float h2 = #{hash}(p + 127.1);", "float h3 = #{hash}(p + 269.5);"]
    hashes << "float h4 = #{hash}(p + 419.2);" if width == 4
    gradient_comment = width == 3 ? "    // Generate 3 independent random values\n" : ""
    corners = (0...(1 << width)).map do |i|
      offset = Array.new(width - 1) { |j| (i >> j) & 1 } + [0]
      z = width == 4 ? "iw#{i >> 3}" : "iz#{i >> 2}"
      base = width == 4 ? "vec4(i.xyz, #{z})" : "vec3(i.xy, #{z})"
      "#{type} c#{i} = #{grad}(#{base} + #{type}(#{offset.join(',')}));"
    end.join("\n")
    selected = width == 4 ? 5 : 1
    <<~GLSL
      uniform int seed;
      out vec4 fragColor;
      float #{hash}(#{type} p) {
          #{coordinate}
          uvec#{width} q = uvec#{width}(ivec#{width}(#{points} * 1000.0) + 65536);
          q = q * 1664525u + 1013904223u;
          #{mixes}
          q ^= q >> 16u;
          #{mixes}
          return float(#{axes.map { |axis| "q.#{axis}" }.join(' ^ ')}) / 4294967295.0;
      }
      #{type} #{grad}(#{type} p) {
      #{gradient_comment}    #{hashes.join("\n    ")}
          return normalize(#{type}(#{(1..width).map { |i| "h#{i} * 2.0 - 1.0" }.join(', ')}));
      }
      void main() {
          #{type} i = #{type}(#{(1..width).to_a.join(',')});
          float iw0 = 4.0; float iw1 = 5.0;
          float iz0 = 3.0; float iz1 = 4.0;
          #{corners}
          fragColor = #{width == 4 ? "c#{selected}" : "vec4(c#{selected}, 1.0)"};
      }
    GLSL
  end

  def test_noise3d_lattice_constants_precede_seed_and_coordinate_adds
    expected = [-0.5453212261199951, -0.45528578758239746, 0.10396884381771088, -0.6960818767547607]
    assert_equal expected, render_probe("synth3d/noise3d", "precompute", lattice_source(4), "seed" => 7)
  end

  def test_perlin_3d_adds_seed_before_the_uniform_z_constant
    expected = [0.5799109935760498, -0.43625524640083313, 0.6880294680595398, 1.0]
    assert_equal expected, render_probe("synth/perlin", "perlin", lattice_source(3), "seed" => 7)
  end

  def test_cell3d_keeps_distinct_x_and_yz_seed_addition_orders
    source = <<~GLSL
      uniform int seed;
      out vec4 fragColor;
      vec3 hash3(vec3 p) {
          p = p + float(seed) * 0.1;
          uvec3 q = uvec3(ivec3(p * 1000.0) + 65536);
          q = pcg3d(q);
          return vec3(q) / 4294967295.0;
      }
      void main() {
          vec3 i = vec3(1,2,3);
          vec3 neighbor = vec3(-1,0,1);
          vec3 cellPos = i + neighbor;
          vec3 randomOffset = hash3(cellPos);
          fragColor = vec4(randomOffset, 1.0);
      }
    GLSL
    assert_equal [0.8656628727912903, 0.4862741231918335, 0.6762023568153381, 1.0],
                 render_probe("synth3d/cell3d", "precompute", source, "seed" => 2)
  end

  def test_volume_simulation_hash_groups_the_dot_terms_before_fract
    source = <<~GLSL
      uniform int seed;
      out vec4 fragColor;
      float hash3(vec3 p) {
          p = p + float(seed) * 0.1;
          p = fract(p * vec3(0.1031, 0.1030, 0.0973));
          p += dot(p, p.yxz + 33.33);
          return fract((p.x + p.y) * p.z);
      }
      void main() { fragColor = vec4(hash3(vec3(31,17,5))); }
    GLSL
    %w[synth3d/reactionDiffusion3d synth3d/cellularAutomata3d].each do |effect|
      assert_equal [0.8681640625] * 4, render_probe(effect, "simulate", source, "seed" => 7), effect
    end
  end
end
