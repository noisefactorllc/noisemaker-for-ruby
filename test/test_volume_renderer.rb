# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/noisemaker_cpu/renderer"

class TestVolumeRenderer < Minitest::Test
  Renderer = NoisemakerCpu::Renderer

  def atlas(volume_size = 4, height: nil)
    {
      "width" => { "param" => "volumeSize", "default" => volume_size },
      "height" => height || { "param" => "volumeSize", "power" => 2, "default" => volume_size**2 },
      "format" => "rgba32f",
    }
  end

  def volume_fixture
    size_param = { "type" => "int", "default" => 4, "uniform" => "volumeSize" }
    effects = {
      "synth3d/volumeSeed" => {
        "namespace" => "synth3d", "func" => "volumeSeed", "kind" => "generator",
        "domain" => "volume-generator", "params" => { "volumeSize" => size_param },
        "paramOrder" => ["volumeSize"], "textures" => { "volumeCache" => atlas, "geoBuffer" => atlas },
        "passes" => [{
          "name" => "seed", "key" => "synth3d/volumeSeed:seed", "drawBuffers" => 2,
          "viewport" => { "width" => atlas["width"], "height" => atlas["height"] },
          "inputs" => {}, "outputs" => { "fragColor" => "volumeCache", "geoOut" => "geoBuffer" },
        }],
        "outputTex3d" => "volumeCache", "outputGeo" => "geoBuffer",
      },
      "synth3d/badVolume" => {
        "namespace" => "synth3d", "func" => "badVolume", "kind" => "generator",
        "domain" => "volume-generator", "params" => { "volumeSize" => size_param },
        "paramOrder" => ["volumeSize"],
        "textures" => { "volumeCache" => { "width" => 4, "height" => 8 }, "geoBuffer" => { "width" => 4, "height" => 8 } },
        "passes" => [{
          "name" => "seed", "key" => "synth3d/volumeSeed:seed", "drawBuffers" => 2,
          "inputs" => {}, "outputs" => { "fragColor" => "volumeCache", "geoOut" => "geoBuffer" },
        }],
        "outputTex3d" => "volumeCache", "outputGeo" => "geoBuffer",
      },
      "filter3d/volumeFilter" => {
        "namespace" => "filter3d", "func" => "volumeFilter", "kind" => "filter",
        "domain" => "volume-filter",
        "params" => { "volumeSize" => { "type" => "int", "default" => 8, "uniform" => "volumeSize" } },
        "paramOrder" => ["volumeSize"],
        "textures" => {
          "volumeCache" => {
            "width" => { "param" => "volumeSize", "inputOverride" => "inputTex3d" },
            "height" => { "param" => "volumeSize", "power" => 2, "inputOverride" => "inputTex3d" },
            "format" => "rgba32f",
          },
        },
        "passes" => [{
          "name" => "filter", "key" => "filter3d/volumeFilter:filter",
          "inputs" => { "volume" => "inputTex3d" }, "outputs" => { "fragColor" => "volumeCache" },
        }],
        "outputTex3d" => "volumeCache", "outputGeo" => "inputGeo",
      },
      "render/volumeRender" => {
        "namespace" => "render", "func" => "volumeRender", "kind" => "filter",
        "domain" => "volume-renderer",
        "params" => { "volumeSize" => { "type" => "int", "default" => 8, "uniform" => "volumeSize" } },
        "paramOrder" => ["volumeSize"], "textures" => {},
        "passes" => [{
          "name" => "render", "key" => "render/volumeRender:render",
          "inputs" => { "volume" => "inputTex3d", "geometry" => "inputGeo" },
          "outputs" => { "fragColor" => "outputTex" },
        }],
        "outputTex3d" => "inputTex3d", "outputGeo" => "inputGeo",
      },
    }
    kernels = {
      "synth3d/volumeSeed:seed" => {
        kernel: lambda do |ctx, out|
          out[0, 8] = [ctx.resolution[0] / 100.0, ctx.resolution[1] / 100.0, 0, 1, 0, 0.75, 0, 1]
        end,
        output_names: %w[fragColor geoOut], uses_derivatives: false,
      },
      "filter3d/volumeFilter:filter" => {
        kernel: lambda do |ctx, out|
          source = ctx.textures.fetch("volume").data
          out[0, 4] = [source[0], source[1], ctx.uniforms["volumeSize"] / 10.0, 1]
        end,
        uses_derivatives: false,
      },
      "render/volumeRender:render" => {
        kernel: lambda do |ctx, out|
          volume = ctx.textures.fetch("volume").data
          geometry = ctx.textures.fetch("geometry").data
          out[0, 4] = [volume[0], volume[1], geometry[1], ctx.uniforms["volumeSize"] / 10.0]
        end,
        uses_derivatives: false,
      },
    }
    [{ "effects" => effects }, kernels]
  end

  def loop_fixture
    effects = {
      "synth/fill" => {
        "namespace" => "synth", "func" => "fill", "kind" => "generator", "domain" => "image",
        "params" => {}, "paramOrder" => [], "textures" => {},
        "passes" => [{ "name" => "fill", "key" => "synth/fill:fill", "inputs" => {}, "outputs" => { "fragColor" => "outputTex" } }],
      },
      "render/loopBegin" => {
        "namespace" => "render", "func" => "loopBegin", "kind" => "filter", "domain" => "loop-begin",
        "loopRole" => "begin", "iterated" => true,
        "params" => { "iterationCount" => { "type" => "int", "default" => 3 } },
        "paramOrder" => ["iterationCount"], "textures" => {},
        "passes" => [{
          "name" => "begin", "key" => "render/loopBegin:begin",
          "inputs" => { "input" => "inputTex", "accum" => "global_accum" },
          "outputs" => { "fragColor" => "outputTex" },
        }],
      },
      "filter/add" => {
        "namespace" => "filter", "func" => "add", "kind" => "filter", "domain" => "image",
        "params" => {}, "paramOrder" => [], "textures" => {},
        "passes" => [{ "name" => "add", "key" => "filter/add:add", "inputs" => { "input" => "inputTex" }, "outputs" => { "fragColor" => "outputTex" } }],
      },
      "render/loopEnd" => {
        "namespace" => "render", "func" => "loopEnd", "kind" => "filter", "domain" => "loop-end",
        "loopRole" => "end", "params" => {}, "paramOrder" => [], "textures" => {},
        "passes" => [
          { "name" => "feedback", "key" => "render/loopEnd:copy", "inputs" => { "input" => "inputTex" }, "outputs" => { "fragColor" => "global_accum" } },
          { "name" => "output", "key" => "render/loopEnd:copy", "inputs" => { "input" => "inputTex" }, "outputs" => { "fragColor" => "outputTex" } },
        ],
      },
    }
    copy = lambda do |ctx, out|
      out[0, 4] = ctx.textures.fetch("input").data[0, 4]
    end
    kernels = {
      "synth/fill:fill" => { kernel: ->(_ctx, out) { out[0, 4] = [0.2, 0, 0, 1] }, uses_derivatives: false },
      "render/loopBegin:begin" => {
        kernel: lambda do |ctx, out|
          out[0, 4] = [ctx.textures.fetch("input").data[0] + ctx.textures.fetch("accum").data[0], 0, 0, 1]
        end,
        uses_derivatives: false,
      },
      "filter/add:add" => {
        kernel: lambda do |ctx, out|
          out[0, 4] = [ctx.textures.fetch("input").data[0] + 0.1, 0, 0, 1]
        end,
        uses_derivatives: false,
      },
      "render/loopEnd:copy" => { kernel: copy, uses_derivatives: false },
    }
    [{ "effects" => effects }, kernels]
  end

  def with_renderer_fixture(meta, kernels)
    original_meta = Renderer.instance_variable_get(:@meta)
    original_kernel_for = Renderer.method(:_kernel_for)
    Renderer.instance_variable_set(:@meta, meta)
    Renderer.define_singleton_method(:_kernel_for, ->(key) { kernels.fetch(key) })
    yield
  ensure
    Renderer.instance_variable_set(:@meta, original_meta)
    Renderer.define_singleton_method(:_kernel_for, original_kernel_for)
  end

  def test_volume_and_geometry_atlases_flow_through_typed_chain
    meta, kernels = volume_fixture
    result = with_renderer_fixture(meta, kernels) do
      Renderer.render_dsl(
        "search synth3d, filter3d, render\n" \
        "volumeSeed(volumeSize: 4).volumeFilter(volumeSize: 8).volumeRender().write(o0)\nrender(o0)",
        width: 2, height: 2
      )
    end

    assert_in_delta 0.04, result.data[0], 0.001
    assert_in_delta 0.16, result.data[1], 0.001
    assert_in_delta 0.75, result.data[2], 0.001
    assert_in_delta 0.4, result.data[3], 0.001
  end

  def test_volume_generator_rejects_noncanonical_atlas_dimensions
    meta, kernels = volume_fixture
    err = assert_raises(RuntimeError) do
      with_renderer_fixture(meta, kernels) do
        Renderer.render_dsl(
          "search synth3d, render\nbadVolume(volumeSize: 4).volumeRender().write(o0)\nrender(o0)",
          width: 2, height: 2
        )
      end
    end
    assert_match(/volume atlas expected 4x16, received 4x8/, err.message)
  end

  def test_loop_region_reuses_accumulator_while_freezing_preloop_input
    meta, kernels = loop_fixture
    result = with_renderer_fixture(meta, kernels) do
      Renderer.render_dsl(
        "search synth, filter, render\nfill().loopBegin(iterationCount: 3).add().loopEnd().write(o0)\nrender(o0)",
        width: 1, height: 1
      )
    end

    assert_in_delta 0.9, result.data[0], 0.002
  end
end
