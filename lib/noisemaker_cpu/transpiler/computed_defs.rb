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
# - render/pointsBillboardRender (reference 0ed489ec, the perspective/depth-sort/
#   defocus round): the reference definition's `.flatMap()` clones its
#   deposit/depthKeys/depthMerge passes per compile-time viewMode/blendMode/
#   blurLayer variant using real Array methods, not a literal passes array.
#   This port's scatter_adapters.rb dispatches viewMode/shapeMode/blendMode as
#   RUNTIME uniforms inside one `billboard_deposit` function rather than
#   compiling per-variant kernels, so the pass list below keeps this port's
#   pre-round shape (diffuse/copy/deposit/deposit_alpha/blend, runtime-gated by
#   `conditions` on `blendMode` — unchanged from before this round) and only
#   the `params` gain this round's new perspective-camera and defocus fields.
#   KNOWN GAP: the depth-sorted alpha-blend draw order (depthKeys/depthMerge,
#   a 22-stage GPU merge sort) and the aperture defocus blur (spriteMeanTiles/
#   spriteMean/clearDefocus precompute + a blurred diffuse composite) are new
#   machinery this round with no equivalent in this port's scanline-rasterizer
#   billboard_deposit, and are NOT ported here -- perspective viewMode and the
#   distance-based size/brightness fade ARE ported (pure per-agent math), but
#   `blendMode: alpha` billboards draw in emission order (not depth-sorted) and
#   `aperture` has no effect. Matches the noisemaker-for-touchdesigner sibling
#   port's own documented defocus gap for the same reason (architecture
#   mismatch with the reference's oversized-quad multi-sample kernel).

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

      def self._points_billboard_render
        params = {
          "shapeMode" => { "type" => "int", "default" => 1, "uniform" => "shapeMode",
                            "choices" => { "texture" => 0, "circle" => 1, "ring" => 2, "square" => 3,
                                           "diamond" => 4, "triangle" => 5, "star" => 6, "soft" => 7 },
                            "randMin" => 1, "ui" => { "label" => "shape", "control" => "dropdown", "category" => "source" } },
          "tex" => { "type" => "surface", "default" => "none",
                     "ui" => { "label" => "sprite", "category" => "source", "enabledBy" => { "param" => "shapeMode", "eq" => 0 } } },
          "blendMode" => { "type" => "int", "default" => 0, "uniform" => "blendMode",
                            "choices" => { "additive" => 0, "alpha" => 1 },
                            "ui" => { "label" => "blend", "control" => "dropdown", "category" => "visual" } },
          "depositOpacity" => { "type" => "float", "default" => 20, "min" => 1, "max" => 100, "uniform" => "depositOpacity",
                                 "ui" => { "label" => "opacity", "control" => "slider", "category" => "visual" } },
          "pointSize" => { "type" => "float", "default" => 8, "min" => 1, "max" => 64, "uniform" => "pointSize",
                            "ui" => { "label" => "point size", "control" => "slider", "category" => "visual" } },
          "sizeVariation" => { "type" => "float", "default" => 0, "min" => 0, "max" => 100, "uniform" => "sizeVariation",
                                "ui" => { "label" => "size variation", "control" => "slider", "category" => "visual" } },
          "rotationVar" => { "type" => "float", "default" => 0, "min" => 0, "max" => 100, "uniform" => "rotationVar",
                              "ui" => { "label" => "rot variation", "control" => "slider", "category" => "visual" } },
          "seed" => { "type" => "int", "default" => 42, "min" => 0, "max" => 1000, "uniform" => "seed",
                       "ui" => { "label" => "seed", "control" => "slider", "category" => "visual" } },
          "density" => { "type" => "float", "default" => 50, "min" => 0, "max" => 100, "uniform" => "density",
                          "ui" => { "label" => "density", "control" => "slider", "category" => "visual" } },
          "intensity" => { "type" => "float", "default" => 75, "min" => 0, "max" => 100, "uniform" => "intensity",
                            "ui" => { "label" => "trail intensity", "control" => "slider", "category" => "visual" } },
          "inputIntensity" => { "type" => "float", "default" => 10.15, "min" => 0, "max" => 100, "randMin" => 50, "uniform" => "inputIntensity",
                                 "ui" => { "label" => "input mix", "control" => "slider", "category" => "visual" } },
          "viewMode" => { "type" => "int", "default" => 0, "uniform" => "viewMode",
                           "choices" => { "flat" => 0, "ortho" => 1, "perspective" => 2 },
                           "ui" => { "label" => "view", "control" => "dropdown", "category" => "view" } },
          "rotateX" => { "type" => "float", "default" => 0.3, "min" => 0, "max" => 6.283185, "uniform" => "rotateX",
                          "ui" => { "label" => "rotate x", "control" => "slider", "category" => "view" } },
          "rotateY" => { "type" => "float", "default" => 0, "min" => 0, "max" => 6.283185, "uniform" => "rotateY",
                          "ui" => { "label" => "rotate y", "control" => "slider", "category" => "view" } },
          "rotateZ" => { "type" => "float", "default" => 0, "min" => 0, "max" => 6.283185, "uniform" => "rotateZ",
                          "ui" => { "label" => "rotate z", "control" => "slider", "category" => "view" } },
          "viewScale" => { "type" => "float", "default" => 0.8, "min" => 0.1, "max" => 10, "uniform" => "viewScale",
                            "ui" => { "label" => "zoom", "control" => "slider", "category" => "view" } },
          "posX" => { "type" => "float", "default" => 0, "min" => -50, "max" => 50, "uniform" => "posX",
                       "ui" => { "label" => "pos x", "control" => "slider", "category" => "view" } },
          "posY" => { "type" => "float", "default" => 0, "min" => -50, "max" => 50, "uniform" => "posY",
                       "ui" => { "label" => "pos y", "control" => "slider", "category" => "view" } },
          "posZ" => { "type" => "float", "default" => 0, "min" => -200, "max" => 200, "uniform" => "posZ",
                       "ui" => { "label" => "pos z", "control" => "slider", "category" => "view" } },
          "fieldOfView" => { "type" => "float", "default" => 60, "min" => 10, "max" => 150, "uniform" => "fieldOfView",
                              "ui" => { "label" => "field of view", "control" => "slider", "category" => "view" } },
          "sizeDistance" => { "type" => "float", "default" => 0, "min" => 0, "max" => 500, "uniform" => "sizeDistance",
                               "ui" => { "label" => "size distance", "control" => "slider", "category" => "view" } },
          "brightnessDistance" => { "type" => "float", "default" => 0, "min" => 0, "max" => 500, "uniform" => "brightnessDistance",
                                     "ui" => { "label" => "brightness distance", "control" => "slider", "category" => "view" } },
          "aperture" => { "type" => "float", "default" => 0, "min" => 0, "max" => 20, "uniform" => "aperture",
                           "ui" => { "label" => "aperture", "control" => "slider", "category" => "view" } },
          "focalDistance" => { "type" => "float", "default" => 80, "min" => 1, "max" => 500, "uniform" => "focalDistance",
                                "ui" => { "label" => "focal distance", "control" => "slider", "category" => "view" } },
        }
        order = %w[shapeMode tex blendMode depositOpacity pointSize sizeVariation rotationVar seed density
                   intensity inputIntensity viewMode rotateX rotateY rotateZ viewScale posX posY posZ
                   fieldOfView sizeDistance brightnessDistance aperture focalDistance]
        deposit_uniforms = {
          "shapeMode" => "shapeMode", "depositOpacity" => "depositOpacity", "density" => "density",
          "pointSize" => "pointSize", "sizeVariation" => "sizeVariation", "rotationVar" => "rotationVar",
          "seed" => "seed", "viewMode" => "viewMode", "rotateX" => "rotateX", "rotateY" => "rotateY",
          "rotateZ" => "rotateZ", "viewScale" => "viewScale", "posX" => "posX", "posY" => "posY",
          "posZ" => "posZ", "fieldOfView" => "fieldOfView", "sizeDistance" => "sizeDistance",
          "brightnessDistance" => "brightnessDistance", "aperture" => "aperture", "focalDistance" => "focalDistance",
        }
        deposit_inputs = { "xyzTex" => "global_xyz", "rgbaTex" => "global_rgba", "spriteTex" => "tex" }
        {
          "namespace" => "render",
          "func" => "pointsBillboardRender",
          "params" => params,
          "paramOrder" => order,
          "passes" => [
            { "name" => "diffuse", "program" => "diffuse", "key" => "render/pointsBillboardRender:diffuse",
              "inputs" => { "trailTex" => "global_billboard_trail" },
              "outputs" => { "fragColor" => "global_billboard_trail" },
              "uniforms" => { "intensity" => "intensity" } },
            { "name" => "copy", "program" => "copy", "key" => "render/pointsBillboardRender:copy",
              "inputs" => { "sourceTex" => "global_billboard_trail" },
              "outputs" => { "fragColor" => "global_billboard_trail" },
              "uniforms" => {} },
            { "name" => "deposit", "program" => "deposit", "key" => nil,
              "inputs" => deposit_inputs, "outputs" => { "fragColor" => "global_billboard_trail" },
              "uniforms" => deposit_uniforms, "blend" => true, "drawMode" => "billboards", "count" => "input",
              "conditions" => { "runIf" => [{ "uniform" => "blendMode", "equals" => 0 }] } },
            { "name" => "deposit_alpha", "program" => "deposit", "key" => nil,
              "inputs" => deposit_inputs, "outputs" => { "fragColor" => "global_billboard_trail" },
              "uniforms" => deposit_uniforms, "blend" => %w[ONE ONE_MINUS_SRC_ALPHA],
              "drawMode" => "billboards", "count" => "input",
              "conditions" => { "runIf" => [{ "uniform" => "blendMode", "equals" => 1 }] } },
            { "name" => "blend", "program" => "blend", "key" => "render/pointsBillboardRender:blend",
              "inputs" => { "inputTex" => "inputTex", "trailTex" => "global_billboard_trail" },
              "outputs" => { "fragColor" => "outputTex" },
              "uniforms" => { "inputIntensity" => "inputIntensity", "blendMode" => "blendMode" } },
          ],
          "textures" => { "global_billboard_trail" => { "width" => "100%", "height" => "100%", "format" => "rgba16f" } },
          "externalTexture" => nil,
        }
      end

      COMPUTED_DEFS = {
        "mixer/mashup" => _mashup,
        "synth/remap" => _remap,
        "render/pointsBillboardRender" => _points_billboard_render,
      }.freeze
    end
  end
end
