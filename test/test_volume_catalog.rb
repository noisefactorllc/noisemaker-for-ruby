# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/noisemaker_cpu/transpiler/build"
require_relative "../lib/noisemaker_cpu/transpiler/cdn"

class TestVolumeCatalog < Minitest::Test
  CDN = NoisemakerCpu::Transpiler::CDN
  Build = NoisemakerCpu::Transpiler::Build

  def with_singleton_stub(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def test_eligible_ids_include_volume_and_loop_effects_but_exclude_mesh_and_reactive
    manifest = %w[
      synth/solid synth/scope classicNoisedeck/noise3d filter3d/flow3d
      render/loopBegin render/loopEnd render/render3d render/meshRender synth3d/noise3d
    ].to_h { |id| [id, {}] }

    ids = with_singleton_stub(CDN, :fetch_manifest, ->(_version = nil) { manifest }) do
      CDN.eligible_ids("test")
    end

    assert_includes ids, "classicNoisedeck/noise3d"
    assert_includes ids, "filter3d/flow3d"
    assert_includes ids, "render/loopBegin"
    assert_includes ids, "render/loopEnd"
    assert_includes ids, "render/render3d"
    assert_includes ids, "synth3d/noise3d"
    refute_includes ids, "render/meshRender"
    refute_includes ids, "synth/scope"
  end

  def test_volume_and_loop_stateful_effects_receive_cpu_iteration_metadata
    %w[filter3d/flow3d render/loopBegin synth3d/cellularAutomata3d synth3d/reactionDiffusion3d].each do |id|
      effect = { "params" => {}, "paramOrder" => [] }
      CDN._add_cpu_iteration_metadata(id, effect)
      assert_equal true, effect["iterated"], id
      assert_equal true, effect.dig("params", "iterationCount", "cpuOnly"), id
    end
  end

  def test_noise3d_hash_is_lowered_to_canonical_cpu_helper
    source = <<~GLSL
      float hash4(vec4 p) {
        uvec4 q = uvec4(ivec4(p * 1000.0) + 65536);
        return float(q.x ^ q.y ^ q.z ^ q.w) / 4294967295.0;
      }
      void main() {
        ivec2 pixelCoord = ivec2(gl_FragCoord.xy);
        int volSize = 4;
        int z = pixelCoord.y / volSize;
      }
    GLSL

    adapted = Build._adapt_source("synth3d/noise3d", "precompute", source)
    assert_includes adapted, "return cpu_noise3d_hash4(p, seed);"
    refute_includes adapted, "uvec4 q"
    assert_includes adapted, "float z = float(pixelCoord.y) / float(volSize);"
  end

  def test_cell3d_hash_result_preserves_canonical_uint_division_order
    source = <<~GLSL
      vec3 hash3(vec3 p) {
        uvec3 q = uvec3(p);
        return vec3(q) / 4294967295.0;
      }
      vec3 cellPoint(vec3 neighbor, vec3 randomOffset, vec3 f, float jitter) {
        vec3 point = neighbor + mix(vec3(0.5), randomOffset, jitter);
        vec3 diff = point - f;
        return diff;
      }
    GLSL

    adapted = Build._adapt_source("synth3d/cell3d", "precompute", source)
    assert_includes adapted, "return cpu_cell3d_hash_result(q);"
    refute_includes adapted, "return vec3(q) / 4294967295.0;"
    refute_includes adapted, "vec3 point ="
    assert_includes adapted, "vec3 diff = neighbor + mix(vec3(0.5), randomOffset, jitter) - f;"
  end

  def test_flythrough3d_struct_is_lowered_like_canonical_cpu_source
    source = <<~GLSL
      struct FractalResult {
        float dist;
        float trap;
        float iterRatio;
      };
      FractalResult sampleResult(FractalResult value) {
        value.dist = value.trap + value.iterRatio;
        return value;
      }
    GLSL

    adapted = Build._adapt_source("synth3d/flythrough3d", "precompute", source)
    refute_includes adapted, "struct FractalResult"
    assert_includes adapted, "vec3 sampleResult(vec3 value)"
    assert_includes adapted, "value.x = value.y + value.z;"
  end

  def test_build_preserves_typed_outputs_domain_and_viewport
    effect = {
      "id" => "synth3d/testVolume",
      "namespace" => "synth3d",
      "func" => "testVolume",
      "params" => { "volumeSize" => { "type" => "int", "default" => 4, "uniform" => "volumeSize" } },
      "paramOrder" => ["volumeSize"],
      "textures" => {
        "volumeCache" => {
          "width" => { "param" => "volumeSize", "default" => 4 },
          "height" => { "param" => "volumeSize", "power" => 2, "default" => 16 },
        },
        "geoBuffer" => {
          "width" => { "param" => "volumeSize", "default" => 4 },
          "height" => { "param" => "volumeSize", "power" => 2, "default" => 16 },
        },
      },
      "passes" => [{
        "name" => "precompute", "program" => "precompute", "inputs" => {},
        "outputs" => { "fragColor" => "volumeCache", "geoOut" => "geoBuffer" },
        "drawBuffers" => 2,
        "viewport" => {
          "width" => { "param" => "volumeSize", "default" => 4 },
          "height" => { "param" => "volumeSize", "power" => 2, "default" => 16 },
        },
      }],
      "outputTex3d" => "volumeCache",
      "outputGeo" => "geoBuffer",
      "programs" => {
        "precompute" => <<~GLSL,
          layout(location = 0) out vec4 fragColor;
          layout(location = 1) out vec4 geoOut;
          void main() { fragColor = vec4(1.0); geoOut = vec4(0.0); }
        GLSL
      },
    }

    Dir.mktmpdir do |dir|
      with_singleton_stub(CDN, :fetch_effect, ->(_id) { effect }) do
        Build.build([effect["id"]], out_dir: dir, update_lock: true)
      end
      built = JSON.parse(File.read(File.join(dir, "metadata.json"))).fetch("effects").fetch(effect["id"])
      assert_equal "generator", built["kind"]
      assert_equal "volume-generator", built["domain"]
      assert_equal "volumeCache", built["outputTex3d"]
      assert_equal "geoBuffer", built["outputGeo"]
      assert_equal effect["passes"][0]["viewport"], built["passes"][0]["viewport"]
    end
  end
end
