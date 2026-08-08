# frozen_string_literal: true

# Hand-ported definitions for effects whose CDN bundle builds globals/passes
# with real JavaScript (loops, spreads) rather than literals, so the static
# extractor can't read them. The GLSL programs are still transpiled from the
# CDN; only the definition (params/passes) is reproduced here.
#
# - mixer/mashup: layer0_tex..layer7_tex surface params (max 8), each with a
#   layerN_active colorModeUniform; wired with `source` into one render pass.
# - synth/remap: zone0_tex..zone7_tex surface params (max 8), each with a
#   zoneN_active colorModeUniform; the std140 `data` block is packed from the
#   params at render time by the Renderer.

module NoisemakerCpu
  module Transpiler
    module ComputedDefs
      MASHUP_LAYERS = 8
      REMAP_ZONES = 8

      def self._mashup
        params = {
          "source" => { "type" => "surface", "default" => "none" },
          "layers" => { "type" => "int", "default" => 4, "uniform" => "layers" },
          "smoothness" => { "type" => "float", "default" => 0.1, "uniform" => "smoothness" },
        }
        order = %w[source layers smoothness]
        inputs = { "source" => "source" }
        (0...MASHUP_LAYERS).each do |e|
          name = "layer#{e}_tex"
          params[name] = { "type" => "surface", "default" => "none", "colorModeUniform" => "layer#{e}_active" }
          inputs[name] = name
          order << name
        end
        {
          "namespace" => "mixer",
          "func" => "mashup",
          "params" => params,
          "paramOrder" => order,
          "passes" => [
            { "name" => "render", "program" => "mashup", "inputs" => inputs, "outputs" => { "fragColor" => "outputTex" } },
          ],
          "textures" => {},
          "externalTexture" => nil,
        }
      end

      def self._remap
        params = {
          "zoneCount" => { "type" => "int", "default" => 0, "uniform" => "zoneCount" },
          "bgColor" => { "type" => "color", "default" => [0, 0, 0], "uniform" => "bgColor" },
          "bgAlpha" => { "type" => "float", "default" => 1, "uniform" => "bgAlpha" },
          "smoothEdge" => { "type" => "float", "default" => 0.04, "uniform" => "smoothEdge" },
        }
        order = %w[zoneCount bgColor bgAlpha smoothEdge]
        inputs = {}
        (0...REMAP_ZONES).each do |z|
          name = "zone#{z}_tex"
          params[name] = { "type" => "surface", "default" => "none", "colorModeUniform" => "zone#{z}_active" }
          inputs[name] = name
          order << name
        end
        {
          "namespace" => "synth",
          "func" => "remap",
          "params" => params,
          "paramOrder" => order,
          "passes" => [
            { "name" => "render", "program" => "remap", "inputs" => inputs, "outputs" => { "fragColor" => "outputTex" } },
          ],
          "textures" => {},
          "externalTexture" => nil,
        }
      end

      COMPUTED_DEFS = {
        "mixer/mashup" => _mashup,
        "synth/remap" => _remap,
      }.freeze
    end
  end
end
