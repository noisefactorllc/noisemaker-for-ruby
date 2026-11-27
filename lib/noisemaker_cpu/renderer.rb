# frozen_string_literal: true

# Render a bundled effect: load metadata + transpiled kernel, run the pass(es).
#
# CPU renderer using the reference engine's canonical
# uniforms matching createCanonicalBindings, seed threading into an effect's
# own `seed` param, texture-filter model (only the declared externalTexture is
# 'linear'; pooled surfaces stay 'nearest'), per-pass quantization to the
# attachment's texture format, multi-pass named-attachment tracking, and
# pass-level uniform aliases.

require "json"

require_relative "kernel_cache"
require_relative "parameters"
require_relative "pass_runner"
require_relative "adapters"
require_relative "draw_ops"
require_relative "external_input"
require_relative "mesh_render"
require_relative "overlay_gen"
require_relative "automation"

require_relative "dsl"
require_relative "runtime"
require_relative "surface"
require_relative "texture_format"
require_relative "palette_data"
require_relative "iteration"
require_relative "scatter_adapters"
require_relative "sink_manager"
require_relative "frame_export_queue"
require_relative "cpu_frame_export_adapter"

module NoisemakerCpu
  # Reactive (MIDI/audio) effects: their kernels read the external-input
  # uniforms bound by render_effect (renderer.js REACTIVE_EFFECT_IDS).
  REACTIVE_EFFECT_IDS = %w[synth/roll synth/scope synth/spectrum].freeze
  # Upstream mesh-texture convention (renderer.js MESH_TEX_WIDTH/HEIGHT).
  MESH_TEX_WIDTH = 256
  MESH_TEX_HEIGHT = 256

  module Renderer
    @cache = NoisemakerCpu::KernelCache.new

    def self.f32(x)
      [x].pack("e").unpack1("e")
    end

    # A published texture may have several names. All of them follow the same
    # attachment when a pass replaces its physical surface.
    TextureBinding = Struct.new(:surface)
    AGENT_CHANNELS = { "outputXyz" => "inputXyz", "outputVel" => "inputVel", "outputRgba" => "inputRgba" }.freeze

    def self._texture_surface(value)
      value.is_a?(TextureBinding) ? value.surface : value
    end

    def self._filtered_surface(surface, mode)
      return surface if surface.filter == mode

      view = surface.dup # A sampler owns its filter and shares the underlying pixels.
      view.filter(mode)
      view
    end

    def self._pass_outputs(pass)
      outputs = pass["outputs"]
      outputs.nil? || outputs.empty? ? (pass["storageTextures"] || {}) : outputs
    end

    def self._chain_bundle?(value)
      value.is_a?(Hash) && value.key?("image")
    end

    def self._chain_bundle(value)
      if _chain_bundle?(value)
        image = value["image"]
        return image.is_a?(TextureBinding) ? value.merge("image" => image.surface, "imageBinding" => image) : value
      end

      { "image" => value, "volume" => nil, "geometry" => nil, "volumeSize" => nil }
    end

    def self._input_bundle(inputs)
      {
        "image" => inputs["inputTex"],
        "volume" => inputs["inputTex3d"],
        "geometry" => inputs["inputGeo"],
        "volumeSize" => inputs["inputTex3d"]&.width,
      }
    end

    def self._inherit_volume_size(eff, params, bundle)
      volume = bundle["volume"]
      domain = eff["domain"] || "image"
      return params if volume.nil? || !(eff["params"] || {}).key?("volumeSize")
      return params unless %w[volume-generator volume-filter volume-renderer].include?(domain)

      size = volume.width
      unless volume.height == size**2
        raise "#{eff['namespace']}/#{eff['func']} input volume atlas expected #{size}x#{size**2}, " \
              "received #{volume.width}x#{volume.height}"
      end
      Parameters.normalize(eff, params).merge("volumeSize" => size)
    end

    def self._bundle_output(name, inherited, resources, group)
      return resources[name] || inherited if name == "inputTex"
      return inherited if name.nil? || name == "inputTex3d" || name == "inputGeo"

      (group && group[name]) || resources[name]
    end

    def self._published_name(field, state)
      fallback = state["effect"][field]
      return fallback unless state["resources"].key?(field)
      return field if (field == "outputTex" && fallback.nil?) || state["outputs"].include?(field)

      fallback
    end

    def self._shared_storage(steps)
      writers = {}
      steps.each do |step|
        (step.dig("definition", "passes") || []).each do |pass|
          (pass["storageTextures"] || {}).each_value do |name|
            next unless name.start_with?("global_") && name != "global_accum" && !Iteration.particle_state_name?(name)

            writers[name] = step
          end
        end
      end
      shared = {}
      writers.each do |name, writer|
        owner = writer
        users = [writer["effect_id"]]
        steps.each do |step|
          eff = step["definition"]
          next unless eff

          if (eff["textures"] || {}).key?(name)
            owner = step
          elsif !eff.values_at("outputTex", "outputTex3d", "outputGeo", *AGENT_CHANNELS.keys).include?(name) &&
                !eff["passes"].any? { |pass| (pass["inputs"] || {}).value?(name) || _pass_outputs(pass).value?(name) }
            next
          end
          users << step["effect_id"]
        end
        shared[name] = [owner, users.uniq, TextureBinding.new] if users.uniq.length > 1
      end
      shared
    end

    def self.bundle_dir
      ENV["NOISEMAKER_BUNDLE"] || File.join(File.dirname(__FILE__), "bundle")
    end

    def self.meta
      return @meta if @meta

      path = File.join(bundle_dir, "metadata.json")
      text = begin
        File.read(path, encoding: "UTF-8")
      rescue SystemCallError => e
        raise "cannot read bundle metadata #{path}: #{e.message}"
      end
      @meta = JSON.parse(text)
    end

    def self._kernel_for(key)
      @cache.get(key, lambda do
        fname = key.gsub(%r{[/:]}, "__")
        path = File.join(bundle_dir, "kernels", "ruby", "#{fname}.rb")
        begin
          File.read(path, encoding: "UTF-8")
        rescue SystemCallError => e
          raise "cannot read kernel #{path}: #{e.message}"
        end
      end)
    end

    def self._coerce(spec, value)
      Parameters.coerce(spec, value)
    end

    # The consumer-range spec upstream's expander builds for automation scaling
    # (shaders/src/runtime/expander.js uniformSpecs): a float/int parameter without
    # choices scales the 0..1 automation output into its declared min..max (0..100
    # when undeclared); an int parameter with choices (a conditional selector) is
    # only rounded to the selected integer, scaled into its declared range when it
    # declares one. Everything else gets no spec, so an automation value resolves
    # unscaled.
    def self._automation_param_spec(spec)
      return nil unless spec.is_a?(Hash)

      type = spec["type"]
      if (type == "float" || type == "int") && !spec["choices"]
        return {
          "min" => spec["min"].nil? ? 0 : spec["min"],
          "max" => spec["max"].nil? ? 100 : spec["max"],
        }
      end
      if type == "int" && spec["choices"]
        result = { "type" => "int" }
        if spec["min"].is_a?(Numeric) && spec["min"].finite? &&
           spec["max"].is_a?(Numeric) && spec["max"].finite?
          result["min"] = spec["min"]
          result["max"] = spec["max"]
        end
        return result
      end
      nil
    end

    # Resolves an `osc(...)` automation value to a concrete number for this
    # render, using the render's normalized time (the same normalized time the
    # canonical kernels receive). Non-automation values coerce as before. The
    # resolved float takes the same Parameters.number f32 rounding an
    # explicitly written numeric parameter takes, so an osc() parameter and
    # its resolved numeric value are interchangeable in the kernel input; a
    # rounded int selector stays an exact Integer (upstream rounds, and the
    # selector contract bypasses the choices re-validation a literal would
    # get, matching the reference engine).
    def self._coerce_param(spec, value, time, float32: true)
      return Parameters.coerce(spec, value, float32) unless Automation.automation_value?(value)

      resolved = Automation.resolve_automation_uniform(value, time, _automation_param_spec(spec))
      resolved.is_a?(Float) ? Parameters.number(resolved, float32: float32) : resolved
    end

    # Pack synth/remap's std140 data[275] block from the bound uniforms --
    # port of the reference remapUniformData. At zoneCount=0 this yields the
    # background color for every pixel.
    def self._remap_uniform_data(u, width, height)
      g = lambda { |name, default| u[name].nil? ? default : u[name] }
      data = Array.new(275) { [0.0, 0.0, 0.0, 0.0] }
      bg = g.call("bgColor", [0, 0, 0])
      data[0] = [bg[0], bg[1], bg[2], g.call("bgAlpha", 1)].map { |c| f32(c) }
      data[1] = [g.call("zoneCount", 0), g.call("smoothEdge", 0.04), 0, g.call("time", 0)].map { |c| f32(c) }
      (0..7).each do |zone|
        data[2 + zone] = [
          g.call("zone#{zone}_count", 0), g.call("zone#{zone}_active", 0),
          0, g.call("zone#{zone}_alpha", 1)
        ].map { |c| f32(c) }
        (0..31).each do |pair|
          v = g.call("zone#{zone}_v#{pair}", [0, 0, 0, 0])
          data[10 + (zone * 32) + pair] = v.map { |c| f32(c) }
        end
        data[267 + zone] = g.call("zone#{zone}_bounds", [0, 0, 1, 1]).map { |c| f32(c) }
      end
      data[266] = [0.0 + width, 0.0 + height, 0, 0]
      data
    end

    # Match the reference engine's createCanonicalBindings.
    def self._canonical_uniforms(width, height, time, seed, effect_uniforms, frame: 0, delta_time: 0.0,
      full_width: width, full_height: height)
      res = [0.0 + width, 0.0 + height]
      full_res = [0.0 + full_width, 0.0 + full_height]
      # Upstream's Pipeline computes these scalar reciprocals on the CPU and
      # uploads them as uniforms instead of dividing in-shader (relaxed-math
      # backends lower a division to an approximate reciprocal multiply). The
      # transpiled kernels read them as plain bindings, so build them the same
      # way: tiling uses the full image's aspect and dimensions, otherwise the
      # render's own.
      aspect_value = full_res[0] / full_res[1]
      aspect = f32(aspect_value)
      u = {
        "renderScale" => f32(1.0),
        "speed" => 0,
        "seed" => f32(seed),
        "centerLoX" => 0,
        "centerLoY" => 0,
        "size" => [0.0, 0.0, 0.0, 0.0],
        "motion" => [0.0, 0.0, 0.0, 0.0]
      }
      u = u.merge(effect_uniforms) # effect params override base defaults
      u.merge(
        "resolution" => res, # canonical values always win
        "fullResolution" => full_res,
        "tileOffset" => [0.0, 0.0],
        "aspectRatio" => aspect,
        "aspect" => aspect,
        "aspectInv" => f32(1.0 / aspect_value),
        "invFullResolution" => [f32(1.0 / full_res[0]), f32(1.0 / full_res[1])],
        "time" => f32(time),
        "globalTime" => f32(time),
        "deltaTime" => f32(delta_time),
        "frame" => frame
      )
    end

    def self._surface_input(spec, name, inputs)
      sampler = spec["texture"] || spec["uniform"] || name
      return inputs[sampler] if inputs.key?(sampler)
      return inputs[name] if inputs.key?(name)

      inputs["inputTex"] if spec["default"] == "inputTex"
    end

    def self._normalize_iteration_params(eff, params, inputs, seed, time: 0.0)
      # The remap CPU adapter reads semantic bindings at authored precision.
      # Its separately packed GPU uniform block still rounds each slot to f32.
      float32 = !(eff["namespace"] == "synth" && eff["func"] == "remap")
      params = Parameters.normalize(eff, params, float32)
      normalized = {}
      effect_uniforms = {}
      surface_params = {}
      (eff["params"] || {}).each do |pname, spec|
        next unless spec.is_a?(Hash)

        if (spec["type"] || "") == "surface"
          sampler = spec["texture"] || spec["uniform"] || pname
          surface = _surface_input(spec, pname, inputs)
          surface_params[sampler] = surface
          normalized[pname] = surface
          effect_uniforms[spec["colorModeUniform"]] = surface.nil? ? 0 : 1 if spec["colorModeUniform"]
          next
        end

        value = if pname == "seed" && !params.key?("seed")
                  _coerce(spec, seed)
                else
                  _coerce_param(spec, params[pname], time, float32: float32)
                end
        normalized[pname] = value
        effect_uniforms[spec["define"] || spec["uniform"] || pname] = value
      end
      [normalized, effect_uniforms, surface_params]
    end

    def self._texture_dimension(spec, axis, params, width, height, resources = nil)
      fallback = axis == :width ? width : height
      return fallback if spec.nil? || spec == "input" || spec == "screen" || spec == "auto" || spec == "resolution" || spec == "100%"
      return [1, spec.round].max if spec.is_a?(Numeric)

      if spec.is_a?(String)
        percent = /\A(\d+(?:\.\d+)?)%\z/.match(spec)
        return [1, (fallback * percent[1].to_f / 100).round].max if percent

        raise "unsupported canonical texture dimension #{spec.inspect}"
      end
      if spec.is_a?(Hash)
        if spec["inputOverride"] && resources
          input = _texture_surface(resources[spec["inputOverride"]])
          return axis == :width ? input.width : input.height if input.respond_to?(:data)
        end
        if spec.key?("param")
          has_transform = spec.key?("power") || spec.key?("multiply")
          param_default = spec["paramDefault"] || spec["default"] || 64
          value = params[spec["param"]]
          value = param_default if value.nil?
          value *= spec["multiply"] if spec.key?("multiply")
          value = value**spec["power"] if spec.key?("power")
          value = spec["default"] if has_transform && !params.key?(spec["param"]) && !spec["default"].nil?
          return [1, value.round].max
        end
        if spec.key?("screenDivide")
          divisor = params[spec["screenDivide"]]
          divisor = spec["default"] if divisor.nil?
          divisor = 1 if divisor.nil?
          divisor = [1, divisor].max
          return [1, fallback.fdiv(divisor).ceil].max
        end
        if spec.key?("scale")
          computed = (fallback * spec["scale"]).floor
          if spec["clamp"].is_a?(Hash)
            computed = [spec["clamp"]["min"], computed].max unless spec["clamp"]["min"].nil?
            computed = [computed, spec["clamp"]["max"]].min unless spec["clamp"]["max"].nil?
          end
          return [1, computed].max
        end
      end
      raise "unsupported canonical texture dimension #{spec.inspect}"
    end

    def self._destination(eff, output_name, params, width, height, pass: nil, resources: nil)
      binding = resources && resources[output_name]
      if binding.is_a?(TextureBinding) && binding.surface
        target = binding.surface
        surface = NoisemakerCpu::Surface.new(target.width, target.height)
        surface.format = target.format
        return surface
      end
      spec = (eff["textures"] || {})[output_name] || {}
      viewport = pass && pass["viewport"] || {}
      width_spec = viewport.key?("w") && !viewport["w"].nil? ? viewport["w"] : (viewport["width"] || spec["width"])
      height_spec = viewport.key?("h") && !viewport["h"].nil? ? viewport["h"] : (viewport["height"] || spec["height"])
      output = NoisemakerCpu::Surface.new(
        _texture_dimension(width_spec, :width, params, width, height, resources),
        _texture_dimension(height_spec, :height, params, width, height, resources)
      )
      output.format = spec["format"] || "rgba16f"
      output
    end

    def self._condition_number(value)
      case value
      when Numeric then value
      when true then 1
      when nil, false then 0
      when String
        value.strip.empty? ? 0 : Float(value, exception: false) || Float::NAN
      else Float::NAN
      end
    end

    def self._pass_active?(pass, uniforms)
      conditions = pass["conditions"]
      return true if conditions.nil?

      matches = lambda do |entry|
        actual = uniforms.fetch(entry["uniform"], Float::NAN)
        _condition_number(actual) == _condition_number(entry.fetch("equals", Float::NAN))
      end
      (conditions["runIf"] || []).all?(&matches) && (conditions["skipIf"] || []).none?(&matches)
    end

    def self._repeat_count(pass, uniforms)
      repeat = pass["repeat"]
      return [0, (uniforms[repeat] || 1).to_i].max if repeat.is_a?(String)

      repeat.nil? ? 1 : repeat.to_i
    end

    # Upstream (shaders/src/runtime/pipeline.js render()) executes each pass
    # exactly resolveRepeatCount(pass) times per frame — there is no group-level
    # multiplier. For iterated effects whose passes carry a `repeat`
    # (synth/navierStokes, synth/reactionDiffusion, synth3d/reactionDiffusion3d)
    # the pass repeat IS the per-frame iteration count, so the group loop must
    # not multiply it again; the documented iterationCount:0 bypass (zero
    # passes run) is still honored. All other iterated effects keep the
    # established `iterationCount` group loop (filter/temporalAberration
    # requires N=60).
    def self._iterated_count(definition, params)
      requested = params["iterationCount"]
      requested = [(requested || 1), 1].min if (definition["passes"] || []).any? { |pass| pass["repeat"] }
      requested.is_a?(Numeric) ? requested : 60
    end

    def self._pass_uniforms(pass, params, base_uniforms)
      uniforms = base_uniforms.dup
      (pass["uniforms"] || {}).each do |uniform_name, source|
        if source.is_a?(String) && params.key?(source)
          uniforms[uniform_name] = params[source]
        elsif source.is_a?(String) && base_uniforms.key?(source)
          uniforms[uniform_name] = base_uniforms[source]
        elsif !(source.is_a?(String) && source == uniform_name && uniforms.key?(uniform_name))
          uniforms[uniform_name] = source
        end
      end
      uniforms.merge!(pass["defines"]) if pass["defines"]
      uniforms
    end

    # A texture dimension spec reading the group's shared `stateSize` through
    # the `inherit: true` flag (upstream's inherited texture dimension): it
    # resolves against the scope's stateSize — `pointsEmit`'s value — and never
    # the behavior's own default over it. Every particle behavior's
    # `global_<behavior>_base_color` memory is sized this way, and several
    # behaviors (flock, hydraulic, lenia, physarum) declare no `stateSize`
    # global of their own.
    def self._declares_inherited_state_size_textures(eff)
      (eff["textures"] || {}).each_value do |texture|
        next unless texture.is_a?(Hash)

        %w[width height].each do |axis|
          spec = texture[axis]
          return true if spec.is_a?(Hash) && spec["inherit"] == true && spec["param"] == "stateSize"
        end
      end
      false
    end

    # The stateSize a step's normalized params observe: the group owner's value
    # whenever the step declares a `stateSize` param — or when its own textures
    # read the scope's stateSize through an `inherit: true` dimension (a joining
    # behavior's base-color memory) — and otherwise the shared particle fallback
    # size for an un-declared inherit-sized texture without an owner. Nil leaves
    # the step's own params untouched.
    def self._inherited_state_size(eff, owner_state_size)
      declares_state_size = (eff["params"] || {}).key?("stateSize")
      inherit_sized = _declares_inherited_state_size_textures(eff)
      if !owner_state_size.nil? && (declares_state_size || inherit_sized)
        owner_state_size
      elsif !declares_state_size && inherit_sized
        PARTICLE_STATE_FALLBACK_SIZE
      end
    end

    def self._initialize_iteration_state(eff, params, inputs, seed, width, height, owner_state_size: nil,
      time: 0.0, step: nil, external_inputs: {}, shared_storage: {}, iterated: true)
      params = _inherit_volume_size(eff, params, _input_bundle(inputs))
      normalized, effect_uniforms, surface_params = _normalize_iteration_params(eff, params, inputs, seed,
                                                                                time: time)
      inherited_state_size = _inherited_state_size(eff, owner_state_size)
      unless inherited_state_size.nil?
        normalized["stateSize"] = inherited_state_size
        state_size_spec = eff["params"]["stateSize"]
        effect_uniforms[state_size_spec["define"] || state_size_spec["uniform"] || "stateSize"] = inherited_state_size if state_size_spec
      end
      standalone_image = !step && !iterated && !eff["domain"].to_s.start_with?("volume-")
      blank = NoisemakerCpu::Surface.new(1, 1)
      outputs = eff["passes"].flat_map { |pass| _pass_outputs(pass).values }.uniq
      reads = eff["passes"].flat_map { |pass| (pass["inputs"] || {}).values }.uniq
      declared = (eff["textures"] || {}).keys
      feedback = (declared & reads & outputs).select { |name| name.start_with?("_") }
      if standalone_image
        # Only physical attachments go in this table. Raw caller inputs and
        # declared sampler bindings have distinct priorities on the standalone API.
        resources = {}
        scratch = feedback - surface_params.keys
        external_resources = {}
      else
        resources = inputs.compact
        surface_params.each { |name, surface| resources[name] = surface || blank }
        scratch = declared.select { |name| iterated || !outputs.include?(name) || feedback.include?(name) }
        external_resources = resources
      end
      _external_bindings(eff, external_resources, effect_uniforms, external_inputs)
      _palette_uniforms(eff, normalized, effect_uniforms)
      overlay_bound = standalone_image ? surface_params.key?("overlayTex") : resources.key?("overlayTex")
      if !iterated && !overlay_bound && declared.include?("overlayTex") && !outputs.include?("overlayTex") &&
         NoisemakerCpu::OverlayGen.is_overlay_effect("#{eff['namespace']}/#{eff['func']}")
        resources["overlayTex"] = NoisemakerCpu::OverlayGen.render_worm_overlay(
          "#{eff['namespace']}/#{eff['func']}", width, height, normalized
        )
      end
      state = {
        "effect" => eff,
        "step" => step,
        "external_inputs" => external_inputs,
        "shared_storage" => shared_storage,
        "outputs" => outputs,
        "scratch" => scratch,
        "blank" => blank,
        "standalone_image" => standalone_image,
        "standalone_external" => standalone_image ? external_resources : nil,
        "standalone_samplers" => step ? {} : surface_params.compact,
        "params" => normalized,
        "effect_uniforms" => effect_uniforms,
        "resources" => resources,
        "self_surface" => nil,
        # The un-normalized params the state was built from (automation values
        # still unresolved), kept so automation-driven params can re-resolve
        # against each iteration's own time (see _refresh_automation_params).
        "raw_params" => params,
        "inputs" => inputs,
        "owner_state_size" => owner_state_size,
      }
      if iterated && (reads.include?("selfTex") || reads.include?("feedback"))
        state["self_surface"] = _destination(eff, "outputTex", normalized, width, height)
        state["self_surface"].clear
        state["resources"]["selfTex"] = state["self_surface"]
        state["resources"]["feedback"] = state["self_surface"]
      end
      state
    end

    # Automation-driven params (`osc(...)`) re-resolve against each iteration's own
    # normalized time: the iteration loop rewinds time to emulate the upstream
    # frames the persistent-texture feedback accumulated, so an osc param must read
    # the same per-iteration time the kernels receive. Returns nil when the step
    # carries no automation, leaving the init-time params object authoritative.
    def self._refresh_automation_params(state, input_bundle, seed, time)
      raw = state["raw_params"]
      return nil if raw.nil? || !raw.any? { |_name, value| Automation.automation_value?(value) }

      eff = state["effect"]
      params = _inherit_volume_size(eff, raw, input_bundle)
      normalized, effect_uniforms, = _normalize_iteration_params(eff, params, state["inputs"], seed, time: time)
      owner = state["owner_state_size"]
      inherited_state_size = _inherited_state_size(eff, owner)
      unless inherited_state_size.nil?
        normalized["stateSize"] = inherited_state_size
        state_size_spec = eff["params"]["stateSize"]
        effect_uniforms[state_size_spec["define"] || state_size_spec["uniform"] || "stateSize"] = inherited_state_size if state_size_spec
      end
      [normalized, effect_uniforms]
    end

    def self._seed_typed_resources(state, input_bundle, width, height, seed, time)
      eff = state["effect"]
      resources = state["resources"]
      id = "#{eff['namespace']}/#{eff['func']}"
      state["shared_storage"].each do |name, (owner, users, binding)|
        next unless users.include?(id)

        unless binding.surface
          owner_params = if owner["effect_id"] == id
                           state["params"]
                         else
                           _normalize_iteration_params(owner["definition"], owner["params"], {}, seed, time: time).first
                         end
          binding.surface = _destination(owner["definition"], name, owner_params, width, height, resources: resources)
        end
        resources[name] = binding
      end
      AGENT_CHANNELS.each_value do |name|
        if !(eff["textures"] || {}).key?("global_xyz") && input_bundle[name]
          resources[name] = input_bundle[name]
        elsif state["step"]
          resources.delete(name)
        end
      end
      (eff["params"] || {}).each do |name, spec|
        next unless spec.is_a?(Hash) && %w[volume geometry].include?(spec["type"])

        input = spec["type"] == "volume" ? input_bundle["volume"] : input_bundle["geometry"]
        if input
          resources[name] = input
          next
        end
        next if resources.key?(name)

        output_name = spec["type"] == "volume" ? eff["outputTex3d"] : eff["outputGeo"]
        unless output_name && (eff["textures"] || {}).key?(output_name)
          raise "#{id} parameter \"#{name}\" requires a #{spec['type']} input" if state["step"]
          next
        end

        resources[name] = _destination(eff, output_name, state["params"], width, height).clear
      end
    end

    PARTICLE_STATE_FALLBACK_SIZE = 256

    PARTICLE_STATE_FALLBACK_FORMATS = {
      "global_xyz" => "rgba32f",
      "global_vel" => "rgba32f",
      "global_rgba" => "rgba8",
      "global_life_data" => "rgba16f",
    }.freeze

    def self._particle_destination(name, states, reference_state, width, height)
      declaring_state = states.find { |candidate| (candidate["effect"]["textures"] || {}).key?(name) }
      if declaring_state
        return _destination(
          declaring_state["effect"], name, declaring_state["params"], width, height
        )
      end

      size = reference_state["params"]["stateSize"] || 256
      surface = NoisemakerCpu::Surface.new(size, size)
      surface.format = PARTICLE_STATE_FALLBACK_FORMATS[name] || "rgba16f"
      surface
    end

    def self._iteration_destination(name, state, states, group, width, height, pass: nil)
      return _particle_destination(name, states, state, width, height) if group && Iteration.particle_state_name?(name)

      _destination(state["effect"], name, state["params"], width, height, pass: pass, resources: state["resources"])
    end

    def self._resource_table(name, state, group)
      group && (Iteration.particle_state_name?(name) || name == "global_accum") ? group : state["resources"]
    end

    def self._iteration_resource(name, state, states, group, width, height)
      table = _resource_table(name, state, group)
      return _texture_surface(table[name]) if table.key?(name)

      if group && Iteration.particle_state_name?(name)
        table[name] = _particle_destination(name, states, state, width, height)
      end
    end

    def self._store_attachment(pass, name, surface, state, group)
      table = _resource_table(name, state, group)
      binding = table[name]
      if pass["blend"] && !pass["drawMode"]
        PassRunner.blend_pass_output(pass["blend"], surface, _texture_surface(binding))
      end
      TextureFormat.quantize_texture(surface, surface.format)
      if binding.is_a?(TextureBinding)
        binding.surface = surface
      else
        table[name] = surface
      end
    end

    def self._bind_step_input(state, input, input_bundle, surfaces, width, height, seed, time)
      eff = state["effect"]
      resources = state["resources"]
      image_resource = input_bundle["imageBinding"] || input_bundle["image"]
      resources["inputTex"] = image_resource if image_resource
      step = state["step"]
      blank = state["blank"]
      refreshed = _refresh_automation_params(state, input_bundle, seed, time)
      if refreshed
        state["params"], uniforms = refreshed
        state["effect_uniforms"].merge!(uniforms)
      end
      if step
        (step["surfaces"] || {}).each do |name, marker|
          resource = marker == "@current" ? image_resource : _resolve_surface_marker(marker, input, surfaces)
          if marker == "@current" && !resource
            raise "#{step['effect_id']} parameter \"#{name}\" requires an input surface"
          end
          spec = eff["params"].fetch(name)
          sampler = spec["texture"] || spec["uniform"] || name
          resources[sampler] = resource || blank
          state["effect_uniforms"][spec["colorModeUniform"]] = resource ? 1 : 0 if spec["colorModeUniform"]
        end
      end
      resources["inputTex3d"] = input_bundle["volume"] unless input_bundle["volume"].nil?
      resources["inputGeo"] = input_bundle["geometry"] unless input_bundle["geometry"].nil?
      if input_bundle["imageBinding"]
        resources.transform_values! { |value| value.equal?(input_bundle["image"]) ? image_resource : value }
      end
      _seed_typed_resources(state, input_bundle, width, height, seed, time)
    end

    def self._pass_textures(pass, state, states, group, width, height, last_output)
      textures = state["standalone_samplers"].dup
      if state["standalone_image"]
        inputs = state["inputs"]
        (pass["inputs"] || {}).each do |sampler, source|
          surface = state["resources"][source] || inputs[source] || state["standalone_external"][source] ||
            inputs[sampler] || last_output
          textures[sampler] = surface if surface
        end
        textures.each do |sampler, surface|
          mode = sampler == state["effect"]["externalTexture"] ? "linear" : "nearest"
          textures[sampler] = _filtered_surface(surface, mode)
        end
        return textures
      end

      step = state["step"]
      (pass["inputs"] || {}).each do |sampler, source|
        surface = _iteration_resource(source, state, states, group, width, height)
        surface ||= state["inputs"][sampler] || last_output unless step
        surface ||= state["blank"] if !step || %w[selfTex feedback].include?(source)
        raise "#{step['effect_id']} pass \"#{pass['name']}\" requires texture \"#{source}\"" unless surface

        textures[sampler] = surface
      end
      textures
    end

    def self._run_iteration_step(state, input, states:, group_resources:, width:, height:, seed:, time:, frame:,
      delta_time:, surfaces: {})
      eff = state["effect"]
      resources = state["resources"]
      input_was_bundle = _chain_bundle?(input)
      input_bundle = _chain_bundle(input)
      _bind_step_input(state, input, input_bundle, surfaces, width, height, seed, time) unless state["standalone_image"]
      blank = state["blank"]
      # Ordinary scratch declarations can size from earlier bindings. An
      # iteration group seeds its private scratch from the parameter sizes.
      state["scratch"].each do |name|
        next if resources.key?(name) || (group_resources && Iteration.particle_state_name?(name))

        resources[name] = _destination(eff, name, state["params"], width, height,
          resources: (group_resources ? nil : resources))
      end
      base_uniforms = _canonical_uniforms(
        width, height, time, seed, state["effect_uniforms"], frame: frame, delta_time: delta_time
      )
      if eff["namespace"] == "synth" && eff["func"] == "remap"
        base_uniforms["data"] = _remap_uniform_data(base_uniforms, width, height)
      end
      rt = NoisemakerCpu::Runtime.new
      last_output = nil

      (eff["passes"] || []).each do |pass|
        next unless _pass_active?(pass, state["effect_uniforms"])

        pass_uniforms = _pass_uniforms(pass, state["params"], base_uniforms)
        repeat = _repeat_count(pass, state["effect_uniforms"])
        repeat.times do
          textures = _pass_textures(pass, state, states, group_resources, width, height, last_output)
          output_names = _pass_outputs(pass).values
          raise "#{eff['func']} pass #{pass['name'].inspect} has no output" if output_names.empty?

          effect_id = "#{eff['namespace']}/#{eff['func']}"
          draw_op = pass["drawMode"] ? NoisemakerCpu::DrawOps.get_draw_op(effect_id, pass["program"]) : nil
          mesh = pass["drawMode"] == "triangles"
          scatter = !pass["drawMode"].nil? && draw_op.nil? && !mesh
          compiled = _kernel_for(pass["key"]) unless scatter || draw_op || mesh
          kernel = compiled && compiled[:kernel]
          adapter = compiled && NoisemakerCpu::Adapters.get_adapter(effect_id, pass["program"])
          kernel = adapter.call(rt, compiled) if adapter
          if compiled && (pass["drawBuffers"] || 0) >= 2 && compiled[:output_names]
            mapped_names = compiled[:output_names].map do |variable|
              destination_name = _pass_outputs(pass)[variable]
              raise "#{eff['func']} pass #{pass['name'].inspect} has no destination for #{variable}" if destination_name.nil?

              destination_name
            end
            destinations = mapped_names.map { |name| _iteration_destination(name, state, states, group_resources, width, height, pass: pass) }
            sizes = destinations.map { |surface| [surface.width, surface.height] }.uniq
            raise "#{eff['func']} pass #{pass['name'].inspect} MRT dimensions differ" unless sizes.length == 1

            # Upstream binds the canvas size as `resolution` to every pass; the pixel
            # loop still covers the state-sized MRT destinations.
            ctx = NoisemakerCpu::Ctx.new(
              rt: rt,
              uniforms: pass_uniforms,
              textures: textures,
              time: time,
              seed: seed,
              blank: blank
            )

            rendered = NoisemakerCpu::PassRunner.run_pass_mrt(
              kernel, ctx, destinations[0].width, destinations[0].height, destinations.length
            )
            rendered.each_with_index do |surface, index|
              surface.format = destinations[index].format
              _store_attachment(pass, mapped_names[index], surface, state, group_resources)
            end
            last_output = rendered[-1]
          else
            output_name = output_names[0]
            destination = _iteration_destination(output_name, state, states, group_resources, width, height, pass: pass)
            pass_uniforms = _pass_uniforms(
              pass,
              state["params"],
              _canonical_uniforms(
                destination.width, destination.height, time, seed, base_uniforms,
                frame: frame, delta_time: delta_time, full_width: width, full_height: height
              )
            )
            ctx = NoisemakerCpu::Ctx.new(
              rt: rt,
              uniforms: pass_uniforms,
              textures: textures,
              resolution: [0.0 + destination.width, 0.0 + destination.height],
              time: time,
              seed: seed,
              blank: blank
            )
            if draw_op || scatter || mesh
              previous = _texture_surface(_resource_table(output_name, state, group_resources)[output_name])
              destination.data.replace(previous.data) if previous && previous.data.length == destination.data.length
              result = destination
              if mesh
                mesh_adapter = NoisemakerCpu::MeshRender.get_adapter(effect_id, pass["program"])
                raise "Missing CPU mesh adapter \"#{effect_id}:#{pass['program']}\"" unless mesh_adapter

                mesh_adapter.call(result, pass_uniforms, state["external_inputs"], pass: pass, inputs: textures)
              elsif draw_op
                source = textures.values.first || textures["inputTex"] || blank
                draw_op.call(source, result, pass_uniforms)
              else
                NoisemakerCpu::ScatterAdapters.run(pass["key"] || "#{effect_id}:#{pass['program']}",
                  pass, pass_uniforms, textures, result)
              end
            else
              result = if compiled[:uses_derivatives]
                       NoisemakerCpu::PassRunner.run_pass_deriv(
                           kernel, ctx, destination.width, destination.height
                         )
                       else
                         NoisemakerCpu::PassRunner.run_pass(
                           kernel, ctx, destination.width, destination.height
                         )
                       end
            end
            result.format = destination.format
            _store_attachment(pass, output_name, result, state, group_resources)
            last_output = result
          end
        end
      end
      return last_output if state["standalone_image"]

      result = _finish_step(state, input_bundle, input_was_bundle, last_output, group_resources)
      if state["self_surface"]
        result_image = _chain_bundle(result)["image"]
        unless state["self_surface"].data.length == result_image.data.length
          raise "#{eff['func']} selfTex dimensions do not match output"
        end
        state["self_surface"].data.replace(result_image.data)
      end
      result
    end

    def self._finish_step(state, input_bundle, input_was_bundle, last_output, group_resources)
      eff = state["effect"]
      resources = state["resources"]
      domain = eff["domain"] || "image"
      volume_domain = domain.start_with?("volume-")
      inherited = eff["outputTex"] || volume_domain ? (input_bundle["imageBinding"] || input_bundle["image"]) : last_output
      image = _bundle_output(_published_name("outputTex", state), inherited, resources, group_resources)
      volume = _texture_surface(_bundle_output(eff["outputTex3d"], input_bundle["volume"], resources, group_resources))
      geometry = _texture_surface(_bundle_output(eff["outputGeo"], input_bundle["geometry"], resources, group_resources))
      volume_size = if domain == "volume-generator"
                      state["params"]["volumeSize"] || volume&.width
                    else
                      input_bundle["volumeSize"] || state["params"]["volumeSize"] || volume&.width
                    end
      if volume_domain && volume.nil? && domain != "volume-renderer"
        raise "#{eff['namespace']}/#{eff['func']} did not produce outputTex3d"
      end
      if volume && %w[volume-generator volume-filter].include?(domain)
        expected_width = volume_size
        expected_height = volume_size**2
        unless volume.width == expected_width && volume.height == expected_height
          raise "#{eff['namespace']}/#{eff['func']} volume atlas expected #{expected_width}x#{expected_height}, " \
                "received #{volume.width}x#{volume.height}"
        end
      end
      bundle = { "image" => image, "volume" => volume, "geometry" => geometry, "volumeSize" => volume_size }
      has_agents = false
      AGENT_CHANNELS.each do |field, input_name|
        name = _published_name(field, state) || input_name
        table = group_resources && group_resources.key?(name) ? group_resources : resources
        resource = table[name]
        next unless resource

        binding = resource.is_a?(TextureBinding) ? resource : (table[name] = TextureBinding.new(resource))
        has_agents = true
        bundle[input_name] = binding
        bundle["image"] = binding if binding.surface.equal?(image)
      end
      if image.nil? && !%w[volume-generator volume-filter].include?(domain)
        raise "#{eff['func']} did not produce outputTex"
      end

      input_was_bundle || volume_domain || has_agents || image.is_a?(TextureBinding) ? bundle : image
    end

    def self._render_iterated_effect(eff, params, inputs, width:, height:, seed:, time:, external_inputs:)
      input_bundle = _input_bundle(inputs)
      typed = %w[volume-generator volume-filter volume-renderer].include?(eff["domain"]) ||
        !input_bundle["volume"].nil? || !input_bundle["geometry"].nil?
      state = _initialize_iteration_state(eff, params, inputs, seed, width, height, time: time, external_inputs: external_inputs)
      states = [state]
      group_resources = {}
      count = _iterated_count(eff, state["params"])
      if count <= 0
        unless typed
          input = inputs["inputTex"]
          return input.clone unless input.nil?

          return NoisemakerCpu::Surface.new(width, height)
        end
        if typed && input_bundle.values_at("image", "volume", "geometry").any?
          return {
            "image" => input_bundle["image"]&.clone,
            "volume" => input_bundle["volume"]&.clone,
            "geometry" => input_bundle["geometry"]&.clone,
            "volumeSize" => input_bundle["volumeSize"],
          }
        end
        if (eff["domain"] || "image") == "volume-generator"
          output_name = eff["outputTex3d"]
          volume = _destination(eff, output_name, state["params"], width, height).clear
          geometry = if eff["outputGeo"] && eff["outputGeo"] != "inputGeo"
                       _destination(eff, eff["outputGeo"], state["params"], width, height).clear
                     end
          return { "image" => nil, "volume" => volume, "geometry" => geometry,
                   "volumeSize" => state["params"]["volumeSize"] || volume.width }
        end

        return NoisemakerCpu::Surface.new(width, height)
      end

      result = nil
      count.times do |index|
        iteration_time = NoisemakerCpu::Iteration.time_for(time, count, index)
        result = _run_iteration_step(
          state, typed ? input_bundle : inputs["inputTex"], states: states, group_resources: group_resources,
          width: width, height: height, seed: seed,
          time: iteration_time, frame: index, delta_time: NoisemakerCpu::Iteration::DELTA_TIME
        )
      end
      result
    end

    def self.render_effect(effect_id, params = nil, inputs = nil, width: 256, height: 256, seed: 1, time: 0.0,
      external_inputs: nil)
      eff = meta["effects"][effect_id]
      raise "unknown effect '#{effect_id}' (not in bundle)" unless eff

      params ||= {}
      inputs = (inputs || {}).transform_keys(&:to_s)
      external_inputs = (external_inputs || {}).transform_keys(&:to_s)
      if eff["iterated"]
        result = _render_iterated_effect(eff, params, inputs, width: width, height: height,
          seed: seed, time: time, external_inputs: external_inputs)
      else
        input = _input_bundle(inputs)
        state = _initialize_iteration_state(eff, params, inputs, seed, width, height,
          time: time, external_inputs: external_inputs, iterated: false)
        result = _run_iteration_step(state, input, states: [state], group_resources: nil, width: width,
          height: height, seed: seed, time: time, frame: 0, delta_time: 0.0)
      end
      # Direct image effects have always returned a Surface. Agent channels
      # travel inside compiled chains, while the standalone volume API returns a bundle.
      return _chain_bundle(result)["image"] unless (eff["domain"] || "image").start_with?("volume-") ||
        (eff["iterated"] && (inputs["inputTex3d"] || inputs["inputGeo"]))

      _chain_bundle(result)
    end

    def self._palette_uniforms(eff, params, effect_uniforms)
      # classicNoisedeck palette presets: a palette-type param > 0 selects
      # cosine-palette coefficients from the shared table.
      if (eff["namespace"] || "") == "classicNoisedeck"
        pal = eff["params"].keys.sort.find do |k|
          eff["params"][k].is_a?(Hash) && (eff["params"][k]["type"] || "") == "palette"
        end
        unless pal.nil?
          idx = params[pal]
          table = NoisemakerCpu::PaletteData::PALETTE_DATA
          idx_s = idx.to_s
          if idx_s =~ /\A\d+\z/ && idx_s.to_i.positive? && idx_s.to_i <= table.length
            e = table[idx_s.to_i - 1]
            effect_uniforms["paletteAmp"] = e[0..2]
            effect_uniforms["paletteFreq"] = e[4..6]
            effect_uniforms["paletteOffset"] = e[8..10]
            effect_uniforms["palettePhase"] = e[12..14]
            effect_uniforms["paletteMode"] = e[3] == 0 ? 3 : e[3].to_i
          end
        end
      end
    end

    def self._external_bindings(eff, resources, uniforms, external_inputs)
      effect_id = "#{eff['namespace']}/#{eff['func']}"
      external = eff["externalTexture"]
      if external && resources[external]
        resources[external] = _filtered_surface(resources.fetch(external), "linear")
      end

      # Reactive (MIDI/audio) uniform defaults and mesh/external data-texture
      # bindings. Mirrors the upstream pipeline's global-uniform stage
      # (renderer.js bindExternalInputs): the 128-float audio arrays and the
      # MIDI clock counter are bound only for the effects whose kernels
      # declare them, zero-initialized when no external state is supplied
      # (like WebGL uniform arrays), and the packed note grid uploads as a
      # 128x16 RGBA data texture. Mesh textures (`global_mesh0_*`) bind from
      # externalInputs.meshData -- the same packed RGBA arrays the upstream
      # uploadMeshData path feeds.
      pass_input_names = {}
      (eff["passes"] || []).each do |pp|
        (pp["inputs"] || {}).each_value { |v| pass_input_names[v] = 1 }
      end
      midi_state = external_inputs["midiState"]
      audio_state = external_inputs["audioState"]
      if REACTIVE_EFFECT_IDS.include?(effect_id)
        uniforms["midiClockCount"] = midi_state ? midi_state.clock_count : 0
        uniforms["audioWaveform"] = audio_state ? audio_state.waveform : Array.new(128, 0.0)
        uniforms["audioSpectrum"] = audio_state ? audio_state.spectrum : Array.new(128, 0.0)
      end
      if REACTIVE_EFFECT_IDS.include?(effect_id) && pass_input_names["midiNoteGrid"]
        grid = midi_state ? midi_state.note_grid : Array.new(128 * 16 * 4, 0.0)
        resources["midiNoteGrid"] ||=
          NoisemakerCpu::ExternalInput.external_data_surface(grid, 128, 16, "rgba32f")
      end
      mesh_names = pass_input_names.keys.select { |n| n.start_with?("global_mesh0_") }
      unless mesh_names.empty?
        # With no meshData, bind the zero mesh upstream samples before an upload.
        mesh_data = external_inputs["meshData"] || NoisemakerCpu::ExternalInput.empty_mesh_data

        tex_width = mesh_data["texWidth"] || MESH_TEX_WIDTH
        tex_height = mesh_data["texHeight"] || MESH_TEX_HEIGHT
        if mesh_names.include?("global_mesh0_positions")
          resources["global_mesh0_positions"] ||=
            NoisemakerCpu::ExternalInput.external_data_surface(mesh_data["positionData"], tex_width, tex_height)
        end
        if mesh_names.include?("global_mesh0_normals")
          resources["global_mesh0_normals"] ||=
            NoisemakerCpu::ExternalInput.external_data_surface(mesh_data["normalData"], tex_width, tex_height)
        end
        if mesh_names.include?("global_mesh0_uvs")
          resources["global_mesh0_uvs"] ||=
            NoisemakerCpu::ExternalInput.external_data_surface(mesh_data["uvData"], tex_width, tex_height)
        end
      end
    end

    # ---- Polymorphic DSL rendering (port of renderer.py render_dsl tail) ----

    # Turn a compiled surface binding into a Surface (or nil for unbound):
    # '@current' is the chain's current image, ['surface', 'oN'] a named
    # surface that must already have been written.
    def self._resolve_surface_marker(marker, current, surfaces)
      return nil if marker.nil?
      return _chain_bundle(current)["image"] if !marker.is_a?(Array) && marker == "@current"

      name = marker[1]
      surf = surfaces[name]
      raise "Surface #{name} has not been written" if surf.nil?

      surf
    end

    def self._run_effect_step(step, current, surfaces, external_textures, width, height, seed, time,
      external_inputs:, shared_storage:)
      inputs = _iteration_step_inputs(step, current, external_textures)
      state = _initialize_iteration_state(step["definition"], step["params"], inputs, seed, width, height,
        time: time, step: step, external_inputs: external_inputs, shared_storage: shared_storage, iterated: false)
      _run_iteration_step(state, current, states: [state], group_resources: nil, width: width, height: height,
        seed: seed, time: time, frame: 0, delta_time: 0.0, surfaces: surfaces)
    end

    def self._iteration_step_inputs(step, current, external_textures)
      inputs = {}
      external = step.dig("definition", "externalTexture")
      if external
        texture = (external_textures || {})[external]
        raise "#{step['effect_id']} requires external texture \"#{external}\"" unless texture

        inputs[external] = texture
      end
      bundle = _chain_bundle(current)
      inputs["inputTex"] = bundle["image"] unless bundle["image"].nil?
      inputs["inputTex3d"] = bundle["volume"] unless bundle["volume"].nil?
      inputs["inputGeo"] = bundle["geometry"] unless bundle["geometry"].nil?
      inputs
    end

    def self._render_iteration_group(group, group_input, surfaces, external_textures, width, height, seed, time, chain_resources,
      external_inputs:, shared_storage:)
      # The authority runs the group's steps in chain order. The iterationCount
      # owner is the group's iterated effect (the merged flow3d group's noise3d
      # input is not iterated and carries no group count); the shared stateSize
      # still comes from the group's first step and reaches every later step's
      # texture sizing and uniforms.
      owner_step = group["steps"].find { |step| step.dig("definition", "iterated") == true } ||
                   group["steps"][0]
      owner_index = group["steps"].index(owner_step)
      # A particle group's owner is its pointsEmit step, which an animated input
      # generator may precede (upstream groupOwnerStateSize): the shared stateSize
      # comes from the step that declares `global_xyz`, not from the group's first
      # step.
      owner_size = nil
      if group["steps"].length > 1
        owner_state_step = group["steps"].find do |step|
          (step.dig("definition", "textures") || {}).key?("global_xyz")
        end || group["steps"][0]
        if owner_state_step.dig("definition", "params", "stateSize")
          # The compiler keeps preset names such as x64. Joining textures and
          # uniforms consume the same numeric stateSize as the emitter.
          owner_params, = _normalize_iteration_params(owner_state_step["definition"],
            owner_state_step["params"], {}, seed, time: time)
          owner_size = owner_params["stateSize"]
        end
      end
      states = group["steps"].each_with_index.map do |step, index|
        inputs = _iteration_step_inputs(step, group_input, external_textures)
        _initialize_iteration_state(step["definition"], step["params"], inputs, seed, width, height,
          owner_state_size: (index.zero? ? nil : owner_size), time: time, step: step,
          external_inputs: external_inputs, shared_storage: shared_storage)
      end

      count = _iterated_count(owner_step["definition"], states[owner_index]["params"])
      if count <= 0 && group_input
        bundle = _chain_bundle(group_input)
        return group_input.clone unless _chain_bundle?(group_input)

        return group_input.merge("image" => bundle["image"]&.clone, "volume" => bundle["volume"]&.clone,
          "geometry" => bundle["geometry"]&.clone)
      end
      return NoisemakerCpu::Surface.new(width, height) if count <= 0

      group_resources = {}
      if group["loop"]
        image = _chain_bundle(group_input)["image"]
        raise "Loop iteration group requires an image input" if image.nil?

        # Upstream scopes the loop accumulator by chain (a global that different
        # effects share keeps its chain scope), so a second loop region in the
        # same chain continues the first region's feedback surface instead of a
        # zeroed one. An inherited surface of the wrong size (cannot arise in one
        # chain's image stream, but guarded) is discarded and re-created.
        inherited = chain_resources && chain_resources["global_accum"]
        if inherited && (inherited.width != image.width || inherited.height != image.height)
          chain_resources.delete("global_accum")
        elsif inherited
          chain_resources.delete("global_accum")
          group_resources["global_accum"] = inherited
        end
        unless group_resources.key?("global_accum")
          accum = NoisemakerCpu::Surface.new(image.width, image.height)
          accum.format = image.format
          group_resources["global_accum"] = accum
        end
      end
      result = nil
      count.times do |index|
        step_input = group_input
        iteration_time = NoisemakerCpu::Iteration.time_for(time, count, index)
        states.each do |state|
          step_input = _run_iteration_step(
            state, step_input, states: states, group_resources: group_resources,
            width: width, height: height, seed: seed, time: iteration_time, frame: index,
            delta_time: NoisemakerCpu::Iteration::DELTA_TIME, surfaces: surfaces
          )
        end
        result = step_input
      end
      # The loop accumulator is chain-scoped: hand it to the chain's next loop
      # region instead of releasing it with the group's other scratch resources.
      accum = group_resources.delete("global_accum")
      chain_resources["global_accum"] = accum if chain_resources && accum
      result
    end

    # Run one compiled chain and return its final value. A step's `inline_chains`
    # (chain arguments such as `tex: solid(color: #f00)`) run before the iteration
    # group that holds the step, and each writes the hidden surface that the step's
    # argument names. Upstream compiles those chains into steps directly ahead of the
    # consuming effect; they read nothing that the group itself writes.
    # The built-in surface I/O steps. read3d starts a chain bundle from a stored
    # volume and geometry; write3d stores the current bundle's volume and geometry
    # under its two names (`none` stores nothing) and passes the chain through, as
    # upstream's `_write3d` blits and passes through.
    def self._render_chain(chain, surfaces, external_textures, width, height, seed, time, external_inputs)
      # The chain-scoped resource map carries the loop accumulator across the
      # chain's loop regions, matching upstream's chain-scoped shared globals.
      # Each inline chain argument is its own chain scope (fresh map inside the
      # recursive call).
      chain_resources = {}
      current = nil
      steps = chain["steps"].map do |step|
        next step unless step["kind"] == "effect"

        step.merge("definition" => meta["effects"].fetch(step["effect_id"]))
      end
      shared_storage = _shared_storage(steps)
      NoisemakerCpu::Iteration.compute_groups(steps).each do |group|
        step = group["steps"][0]
        case step["kind"]
        when "read"
          current = surfaces[step["surface"]]
          raise "Surface #{step['surface']} has not been written" if current.nil?
        when "read3d"
          volume = surfaces[step["volume"]]
          raise "Surface #{step['volume']} has not been written" if volume.nil?

          current = {
            "image" => nil, "volume" => volume, "geometry" => surfaces[step["geometry"]],
            "volumeSize" => volume.width,
          }
        when "write"
          image = _chain_bundle(current)["image"]
          raise "write(surface) requires a current image" if image.nil?

          surfaces[step["surface"]] = image
        when "write3d"
          bundle = _chain_bundle(current)
          surfaces[step["volume"]] = bundle["volume"] if step["volume"] != "none" && bundle["volume"]
          surfaces[step["geometry"]] = bundle["geometry"] if step["geometry"] != "none" && bundle["geometry"]
        else
          group["steps"].each do |effect_step|
            (effect_step["inline_chains"] || []).each do |inline|
              value = _render_chain(
                inline["chain"], surfaces, external_textures, width, height, seed, time, external_inputs
              )
              image = _chain_bundle(value)["image"]
              raise "write(surface) requires a current image" if image.nil?

              surfaces[inline["surface"]] = image
            end
          end
          if group["iterated"]
            current = _render_iteration_group(
              group, current, surfaces, external_textures, width, height, seed, time, chain_resources,
              external_inputs: external_inputs, shared_storage: shared_storage
            )
          else
            group["steps"].each do |effect_step|
              current = _run_effect_step(
                effect_step, current, surfaces, external_textures, width, height, seed, time,
                external_inputs: external_inputs, shared_storage: shared_storage
              )
            end
          end
        end
      end
      current
    end

    # Render a Polymorphic DSL program on the CPU -- the Ruby counterpart of
    # noisemaker-cpu's CpuRenderer.render(). Compiles the program to a plan,
    # then threads each chain's `current` surface through read/write/read3d/
    # write3d/effect steps over a named-surface map (o0..o7, volN/geoN, inline:N),
    # using the same pass runner for ordinary and iterated effects.
    def self.render_dsl(source, width: 512, height: 512, seed: 1, time: 0.0, external_textures: nil,
      seed_surfaces: nil, external_inputs: nil)
      surfaces = (seed_surfaces || {}).dup
      external_inputs = (external_inputs || {}).transform_keys(&:to_s)
      external_textures = (external_textures || {}).transform_keys(&:to_s)
      plan = NoisemakerCpu::DSL.compile_dsl(source, meta["effects"])
      plan["chains"].each do |chain|
        _render_chain(chain, surfaces, external_textures, width, height, seed, time, external_inputs)
      end
      rendered = surfaces[plan["render_surface"]]
      raise "Surface #{plan['render_surface']} has not been written" if rendered.nil?

      rendered
    end
  end

  class CpuRenderer
    attr_reader :sink_manager

    # Pass an isolated sink failure to the sink that threw it. A sink opts in
    # with an optional on_error(error) method, for example to end an output
    # whose new size it cannot send. Rendering and the other sinks continue
    # either way. `onError` is accepted under the engine's own name.
    SINK_ERROR_METHODS = %i[on_error onError].freeze

    def self.report_sink_error(error, sink)
      name = SINK_ERROR_METHODS.find { |candidate| sink.respond_to?(candidate) }
      sink.public_send(name, error) if name
    end

    def initialize(on_sink_error: nil)
      on_sink_error ||=
        ->(error, sink) { NoisemakerCpu::CpuRenderer.report_sink_error(error, sink) }
      @sink_manager = NoisemakerCpu::SinkManager.new(on_error: on_sink_error)
      @sink_descriptor = {
        "width" => 0, "height" => 0, "format" => "rgba8unorm",
        "colorSpace" => "srgb", "alphaMode" => "straight", "fps" => 60
      }
      @sinks_configured = false
    end

    def add_sink(sink)
      @sink_manager.add(sink)
    end

    def should_defer_render
      @sink_manager.should_defer_render
    end
    alias shouldDeferRender should_defer_render

    def create_frame_export_queue(slots: 3, on_error: nil)
      NoisemakerCpu::FrameExportQueue.new(
        NoisemakerCpu::CpuFrameExportAdapter.new, slots: slots, on_error: on_error
      )
    end

    def render(source, width: 512, height: 512, seed: 1, time: 0.0,
      external_textures: nil, seed_surfaces: nil, presentation_timestamp: nil)
      validate_options(width, height, seed, time)
      configure_sinks(width, height)
      result = NoisemakerCpu::Renderer.render_dsl(
        source, width: width, height: height, seed: seed, time: time,
        external_textures: external_textures, seed_surfaces: seed_surfaces
      )
      timestamp = presentation_timestamp.nil? ? monotonic_milliseconds : presentation_timestamp
      @sink_manager.submit(result, timestamp)
      result
    end

    def dispose
      @sink_manager.close
    end

    private

    def validate_options(width, height, seed, time)
      raise ArgumentError, "width must be a positive integer" unless width.is_a?(Integer) && width.positive?
      raise ArgumentError, "height must be a positive integer" unless height.is_a?(Integer) && height.positive?
      unless time.is_a?(Numeric) && time.real? && time.to_f.finite?
        raise TypeError, "time must be finite"
      end
      raise TypeError, "seed must be an integer" unless seed.is_a?(Integer)
    end

    def configure_sinks(width, height)
      unchanged = @sink_descriptor["width"] == width && @sink_descriptor["height"] == height
      return if @sinks_configured && unchanged

      @sink_descriptor["width"] = width
      @sink_descriptor["height"] = height
      @sinks_configured = true
      @sink_manager.configure(@sink_descriptor)
    end

    def monotonic_milliseconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
    end
  end
end
