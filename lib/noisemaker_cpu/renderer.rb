# frozen_string_literal: true

# Render a bundled effect: load metadata + transpiled kernel, run the pass(es).
#
# Faithful port of the (167/167 parity-proven) Python/Perl renderer: canonical
# uniforms matching createCanonicalBindings, seed threading into an effect's
# own `seed` param, texture-filter model (only the declared externalTexture is
# 'linear'; pooled surfaces stay 'nearest'), per-pass quantization to the
# attachment's texture format, multi-pass named-attachment tracking, and
# pass-level uniform aliases.

require "json"

require_relative "kernel_cache"
require_relative "pass_runner"
require_relative "adapters"
require_relative "draw_ops"
require_relative "overlay_gen"

require_relative "dsl"
require_relative "runtime"
require_relative "surface"
require_relative "texture_format"
require_relative "palette_data"
require_relative "iteration"
require_relative "scatter_adapters"

module NoisemakerCpu
  module Renderer
    @cache = NoisemakerCpu::KernelCache.new

    def self.f32(x)
      [x].pack("e").unpack1("e")
    end

    def self.bundle_dir
      ENV["NOISEMAKER_BUNDLE"] || File.join(File.dirname(__FILE__), "bundle")
    end

    def self.meta
      return @meta if @meta

      path = File.join(bundle_dir, "metadata.json")
      text = begin
        File.read(path)
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
          File.read(path)
        rescue SystemCallError => e
          raise "cannot read kernel #{path}: #{e.message}"
        end
      end)
    end

    def self._parse_hex(s)
      s = s.delete_prefix("#")
      s = s.chars.map { |c| c * 2 }.join if s.length == 3
      rgb = (0..2).map { |i| s[i * 2, 2].to_i(16).fdiv(255.0) }
      rgb << s[6, 2].to_i(16).fdiv(255.0) if s.length >= 8
      rgb
    end

    def self._coerce(spec, value)
      t = spec["type"] || ""
      value = spec["default"] if value.nil?
      if t == "color"
        value = _parse_hex(value) if !value.nil? && !value.is_a?(Array)
        return (value || [0, 0, 0]).map { |c| f32(c) }
      end
      if t == "vec2" || t == "vec3" || t == "vec4"
        if !value.nil? && !value.is_a?(Array) # CLI --param: "0.1,0.2,0.3"
          value = value.split(",").map { |x| 0 + x.to_f }
        end
        return (value || []).map { |c| f32(c) }
      end
      return f32(value.nil? ? 0 : value) if t == "float"
      if t == "int" || t == "enum" || t == "member"
        if !value.nil? && value.to_s =~ /[^\d\s.+-]/ # enum name lookup
          choices = spec["choices"] || {}
          m = value.to_s.match(/([^.]+)\z/) # "oscType.sine" -> "sine"
          key = m ? m[1] : nil
          return choices[value].to_i if choices.key?(value)
          return choices[key].to_i if !key.nil? && choices.key?(key)

          return 0 # CDN member with no inline choices: 0th member
        end
        return (value.nil? ? 0 : value).to_i
      end
      if t == "bool" || t == "boolean"
        return 1 if !value.nil? && value.to_s =~ /\A\s*(?:true|yes|on)\s*\z/i
        return 0 if !value.nil? && value.to_s =~ /\A\s*(?:false|no|off)\s*\z/i

        return (!value.nil? && value) ? 1 : 0
      end
      value
    end

    # Pack synth/remap's std140 data[267] block from the bound uniforms --
    # port of the reference remapUniformData. At zoneCount=0 this yields the
    # background color for every pixel.
    def self._remap_uniform_data(u, width, height)
      g = lambda { |name, default| u[name].nil? ? default : u[name] }
      data = Array.new(267) { [0.0, 0.0, 0.0, 0.0] }
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
      end
      data[266] = [0.0 + width, 0.0 + height, 0, 0]
      data
    end

    # Match the reference engine's createCanonicalBindings.
    def self._canonical_uniforms(width, height, time, seed, effect_uniforms, frame: 0, delta_time: 0.0,
      full_width: width, full_height: height)
      res = [0.0 + width, 0.0 + height]
      full_res = [0.0 + full_width, 0.0 + full_height]
      aspect = f32(width.fdiv(height))
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
        "time" => f32(time),
        "globalTime" => f32(time),
        "deltaTime" => f32(delta_time),
        "frame" => frame
      )
    end

    def self._normalize_iteration_params(eff, params, inputs, seed)
      normalized = {}
      effect_uniforms = {}
      surface_params = {}
      (eff["params"] || {}).each do |pname, spec|
        next unless spec.is_a?(Hash)

        if (spec["type"] || "") == "surface"
          sampler = spec["uniform"] || spec["texture"] || pname
          surface = inputs[sampler].nil? ? inputs[pname] : inputs[sampler]
          surface_params[sampler] = surface
          normalized[pname] = surface
          effect_uniforms[spec["colorModeUniform"]] = surface.nil? ? 0 : 1 if spec["colorModeUniform"]
          next
        end

        value = if pname == "seed" && !params.key?("seed")
                  _coerce(spec, seed)
                else
                  _coerce(spec, params[pname])
                end
        normalized[pname] = value
        effect_uniforms[spec["uniform"]] = value unless spec["uniform"].nil?
        effect_uniforms[spec["define"]] = value unless spec["define"].nil?
      end
      [normalized, effect_uniforms, surface_params]
    end

    def self._texture_dimension(spec, axis, params, width, height)
      fallback = axis == :width ? width : height
      return fallback if spec.nil? || spec == "input" || spec == "screen" || spec == "100%"
      return [1, spec.round].max if spec.is_a?(Numeric)

      if spec.is_a?(String)
        percent = /\A(\d+(?:\.\d+)?)%\z/.match(spec)
        return [1, (fallback * percent[1].to_f / 100).round].max if percent

        raise "unsupported canonical texture dimension #{spec.inspect}"
      end
      if spec.is_a?(Hash)
        if spec.key?("param")
          value = params[spec["param"]]
          value = spec["paramDefault"] || spec["default"] if value.nil?
          return [1, value.round].max
        end
        if spec.key?("screenDivide")
          divisor = params[spec["screenDivide"]]
          divisor = spec["default"] if divisor.nil?
          divisor = [1, divisor].max
          return [1, fallback.fdiv(divisor).ceil].max
        end
      end
      raise "unsupported canonical texture dimension #{spec.inspect}"
    end

    def self._destination(eff, output_name, params, width, height)
      spec = (eff["textures"] || {})[output_name] || {}
      output = NoisemakerCpu::Surface.new(
        _texture_dimension(spec["width"], :width, params, width, height),
        _texture_dimension(spec["height"], :height, params, width, height)
      )
      output.format = spec["format"] || "rgba16f"
      output
    end

    def self._pass_active?(pass, uniforms)
      conditions = pass["conditions"]
      return true if conditions.nil?

      (conditions["runIf"] || []).each do |entry|
        return false unless uniforms[entry["uniform"]].to_f == entry["equals"].to_f
      end
      (conditions["skipIf"] || []).each do |entry|
        return false if uniforms[entry["uniform"]].to_f == entry["equals"].to_f
      end
      true
    end

    def self._repeat_count(pass, uniforms)
      repeat = pass["repeat"]
      return [0, (uniforms[repeat] || 1).to_i].max if repeat.is_a?(String)

      repeat.nil? ? 1 : repeat.to_i
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
      uniforms
    end

    def self._initialize_iteration_state(eff, params, inputs, seed, width, height, owner_state_size: nil)
      normalized, effect_uniforms, surface_params = _normalize_iteration_params(eff, params, inputs, seed)
      if !owner_state_size.nil? && (eff["params"] || {}).key?("stateSize")
        normalized["stateSize"] = owner_state_size
        state_size_spec = eff["params"]["stateSize"]
        effect_uniforms[state_size_spec["uniform"]] = owner_state_size unless state_size_spec["uniform"].nil?
      end
      resources = {}
      inputs.each { |name, surface| resources[name] = surface unless surface.nil? }
      surface_params.each { |name, surface| resources[name] = surface unless surface.nil? }
      state = {
        "effect" => eff,
        "params" => normalized,
        "effect_uniforms" => effect_uniforms,
        "resources" => resources,
        "self_surface" => nil,
      }
      reads_self = (eff["passes"] || []).any? do |pass|
        (pass["inputs"] || {}).values.any? { |name| name == "selfTex" || name == "feedback" }
      end
      if reads_self
        state["self_surface"] = _destination(eff, "outputTex", normalized, width, height)
        state["self_surface"].clear
        state["resources"]["selfTex"] = state["self_surface"]
        state["resources"]["feedback"] = state["self_surface"]
      end
      state
    end

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

    def self._iteration_destination(name, state, states, width, height)
      return _particle_destination(name, states, state, width, height) if NoisemakerCpu::Iteration.particle_state_name?(name)

      _destination(state["effect"], name, state["params"], width, height)
    end

    def self._iteration_resource(name, state, states, group_resources, width, height)
      if NoisemakerCpu::Iteration.particle_state_name?(name)
        group_resources[name] ||= _particle_destination(name, states, state, width, height).clear
      else
        state["resources"][name]
      end
    end

    def self._ensure_iteration_resources(state, width, height)
      eff = state["effect"]
      (eff["textures"] || {}).each_key do |name|
        next if NoisemakerCpu::Iteration.particle_state_name?(name)
        next if state["resources"].key?(name)

        state["resources"][name] = _destination(eff, name, state["params"], width, height).clear
      end
    end

    def self._run_iteration_step(state, input, states:, group_resources:, width:, height:, seed:, time:, frame:,
      delta_time:)
      eff = state["effect"]
      resources = state["resources"]
      resources["inputTex"] = input unless input.nil?
      _ensure_iteration_resources(state, width, height)
      base_uniforms = _canonical_uniforms(
        width, height, time, seed, state["effect_uniforms"], frame: frame, delta_time: delta_time
      )
      blank = NoisemakerCpu::Surface.new(1, 1)
      rt = NoisemakerCpu::Runtime.new
      last_output = nil

      (eff["passes"] || []).each do |pass|
        pass_uniforms = _pass_uniforms(pass, state["params"], base_uniforms)
        next unless _pass_active?(pass, pass_uniforms)

        repeat = _repeat_count(pass, pass_uniforms)
        repeat.times do
          textures = {}
          (pass["inputs"] || {}).each do |uniform_name, resource_name|
            surface = _iteration_resource(resource_name, state, states, group_resources, width, height)
            surface = blank if surface.nil? && (resource_name == "selfTex" || resource_name == "feedback")
            surface ||= blank
            textures[uniform_name] = surface
          end
          output_names = (pass["outputs"] || {}).values
          raise "#{eff['func']} pass #{pass['name'].inspect} has no output" if output_names.empty?

          scatter = pass["drawMode"] == "points" || pass["drawMode"] == "billboards"
          compiled = _kernel_for(pass["key"]) unless scatter
          if !scatter && (pass["drawBuffers"] || 0) >= 2 && compiled[:output_names]
            mapped_names = compiled[:output_names].map do |variable|
              destination_name = (pass["outputs"] || {})[variable]
              raise "#{eff['func']} pass #{pass['name'].inspect} has no destination for #{variable}" if destination_name.nil?

              destination_name
            end
            destinations = mapped_names.map { |name| _iteration_destination(name, state, states, width, height) }
            sizes = destinations.map { |surface| [surface.width, surface.height] }.uniq
            raise "#{eff['func']} pass #{pass['name'].inspect} MRT dimensions differ" unless sizes.length == 1

            pass_uniforms = _pass_uniforms(
              pass,
              state["params"],
              _canonical_uniforms(
                destinations[0].width, destinations[0].height, time, seed, state["effect_uniforms"],
                frame: frame, delta_time: delta_time, full_width: width, full_height: height
              )
            )
            ctx = NoisemakerCpu::Ctx.new(
              rt: rt,
              uniforms: pass_uniforms,
              textures: textures,
              time: time,
              seed: seed,
              blank: blank
            )

            rendered = NoisemakerCpu::PassRunner.run_pass_mrt(
              compiled[:kernel], ctx, destinations[0].width, destinations[0].height, destinations.length
            )
            rendered.each_with_index do |surface, index|
              surface.format = destinations[index].format
              NoisemakerCpu::TextureFormat.quantize_texture(surface, surface.format)
              if NoisemakerCpu::Iteration.particle_state_name?(mapped_names[index])
                group_resources[mapped_names[index]] = surface
              else
                resources[mapped_names[index]] = surface
              end
            end
            last_output = rendered[-1]
          else
            output_name = output_names[0]
            destination = _iteration_destination(output_name, state, states, width, height)
            pass_uniforms = _pass_uniforms(
              pass,
              state["params"],
              _canonical_uniforms(
                destination.width, destination.height, time, seed, state["effect_uniforms"],
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
            if scatter
              previous = _iteration_resource(output_name, state, states, group_resources, width, height)
              destination.data.replace(previous.data) if previous && previous.data.length == destination.data.length
              result = destination
              NoisemakerCpu::ScatterAdapters.run(pass["key"] || "#{eff['namespace']}/#{eff['func']}:#{pass['program']}",
                pass, pass_uniforms, textures, result)
            else
              result = if compiled[:uses_derivatives]
                         NoisemakerCpu::PassRunner.run_pass_deriv(
                           compiled[:kernel], ctx, destination.width, destination.height
                         )
                       else
                         NoisemakerCpu::PassRunner.run_pass(
                           compiled[:kernel], ctx, destination.width, destination.height
                         )
                       end
            end
            result.format = destination.format
            NoisemakerCpu::TextureFormat.quantize_texture(result, result.format)
            if NoisemakerCpu::Iteration.particle_state_name?(output_name)
              group_resources[output_name] = result
            else
              resources[output_name] = result
            end
            last_output = result
          end
        end
      end
      result = resources["outputTex"] || last_output
      raise "#{eff['func']} did not produce outputTex" if result.nil?

      if state["self_surface"]
        unless state["self_surface"].data.length == result.data.length
          raise "#{eff['func']} selfTex dimensions do not match output"
        end
        state["self_surface"].data.replace(result.data)
      end
      result
    end

    def self._render_iterated_effect(eff, params, inputs, width:, height:, seed:, time:)
      state = _initialize_iteration_state(eff, params, inputs, seed, width, height)
      states = [state]
      group_resources = {}
      count = state["params"]["iterationCount"] || 60
      if count <= 0
        input = inputs["inputTex"]
        return input.clone unless input.nil?

        return NoisemakerCpu::Surface.new(width, height)
      end

      result = nil
      count.times do |index|
        iteration_time = NoisemakerCpu::Iteration.time_for(time, count, index)
        result = _run_iteration_step(
          state, inputs["inputTex"], states: states, group_resources: group_resources,
          width: width, height: height, seed: seed,
          time: iteration_time, frame: index, delta_time: NoisemakerCpu::Iteration::DELTA_TIME
        )
      end
      result
    end

    def self.render_effect(effect_id, params = nil, inputs = nil, width: 256, height: 256, seed: 1, time: 0.0)
      params ||= {}
      inputs ||= {}
      eff = meta["effects"][effect_id]
      raise "unknown effect '#{effect_id}' (not in bundle)" if eff.nil?
      return _render_iterated_effect(eff, params, inputs, width: width, height: height, seed: seed, time: time) if eff["iterated"]

      effect_uniforms = {}
      surface_params = {} # sampler-name -> provided Surface (or nil)
      eff["params"].keys.sort.each do |pname|
        spec = eff["params"][pname]
        next unless spec.is_a?(Hash)

        if (spec["type"] || "") == "surface"
          sampler = spec["uniform"] || spec["texture"] || pname
          surf = inputs[sampler].nil? ? inputs[pname] : inputs[sampler]
          surface_params[sampler] = surf
          # colorModeUniform (e.g. mashup's layerN_active): 1 when the
          # surface is wired, 0 when unbound.
          effect_uniforms[spec["colorModeUniform"]] = surf.nil? ? 0 : 1 if spec["colorModeUniform"]
          next
        end
        val =
          if pname == "seed" && !params.key?("seed")
            # An effect's own `seed` param shares the GLSL uniform name with
            # the canonical render seed: thread the render seed into it so
            # `seed=` actually changes the generator's look (the big parity
            # unlock in the Python port).
            _coerce(spec, seed)
          else
            _coerce(spec, params[pname])
          end
        effect_uniforms[spec["uniform"]] = val unless spec["uniform"].nil?
        effect_uniforms[spec["define"]] = val unless spec["define"].nil?
      end

      # classicNoisedeck palette presets: a palette-type param > 0 selects
      # cosine-palette coefficients from the shared table.
      if (eff["namespace"] || "") == "classicNoisedeck"
        pal = eff["params"].keys.sort.find do |k|
          eff["params"][k].is_a?(Hash) && (eff["params"][k]["type"] || "") == "palette"
        end
        unless pal.nil?
          idx = _coerce(eff["params"][pal], params[pal])
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

      uniforms = _canonical_uniforms(width, height, time, seed, effect_uniforms)
      uniforms["data"] = _remap_uniform_data(uniforms, width, height) if effect_id == "synth/remap"
      blank = NoisemakerCpu::Surface.new(1, 1)

      rt = NoisemakerCpu::Runtime.new
      result = nil
      attachments = {} # attach-name -> Surface produced by an earlier pass

      # One-shot CPU-generated textures declared but not produced by any pass
      # (fibers/scratches/strayHair overlayTex): generate and bind up front.
      if NoisemakerCpu::OverlayGen.is_overlay_effect(effect_id)
        produced = {}
        (eff["passes"] || []).each do |pp|
          (pp["outputs"] || {}).each_value { |v| produced[v] = 1 }
        end
        (eff["textures"] || {}).keys.sort.each do |tname|
          next unless tname == "overlayTex" && !produced[tname] && !surface_params.key?(tname)

          gen = {}
          ["seed", "density"].each do |pn|
            next unless eff["params"].key?(pn)

            gp = eff["params"][pn]
            gen[pn] = (pn == "seed" && !params.key?("seed")) ? _coerce(gp, seed) : _coerce(gp, params[pn])
          end
          attachments[tname] = NoisemakerCpu::OverlayGen.render_worm_overlay(effect_id, width, height, gen)
        end
      end

      # Texture filtering must match the oracle: only the declared external
      # texture is 'linear'; every pooled surface stays 'nearest' (decisive
      # for warp effects sampling at fractional coordinates).
      external_tex = eff["externalTexture"]

      (eff["passes"] || []).each do |p|
        textures = {}
        surface_params.keys.sort.each do |sampler|
          surf = surface_params[sampler]
          next if surf.nil?

          surf.filter((!external_tex.nil? && sampler == external_tex) ? "linear" : "nearest")
          textures[sampler] = surf
        end
        (p["inputs"] || {}).keys.sort.each do |sampler_name|
          source = p["inputs"][sampler_name]
          # An earlier pass's named attachment wins over a same-named
          # external input.
          surf = attachments[source] || inputs[source] || inputs[sampler_name] || result
          next if surf.nil?

          surf.filter((!external_tex.nil? && sampler_name == external_tex) ? "linear" : "nearest")
          textures[sampler_name] = surf
        end
        # Pass-level uniform aliases: the definition may expose a param under
        # one name while this pass's GLSL declares another.
        pass_uniforms = uniforms.dup
        (p["uniforms"] || {}).keys.sort.each do |glsl_name|
          param_name = p["uniforms"][glsl_name]
          if effect_uniforms.key?(param_name)
            pass_uniforms[glsl_name] = effect_uniforms[param_name]
          elsif uniforms.key?(param_name)
            pass_uniforms[glsl_name] = uniforms[param_name]
          end
        end
        # Sorted for determinism: every current pass has at most one output,
        # but hash order must never pick the format-defining attachment.
        out_names = (p["outputs"] || {}).keys.sort.map { |k| p["outputs"][k] }
        fmt = "rgba16f"
        if !out_names.empty? && eff["textures"] && eff["textures"][out_names[0]]
          fmt = eff["textures"][out_names[0]]["format"] || "rgba16f"
        end
        draw_op = p["drawMode"] ? NoisemakerCpu::DrawOps.get_draw_op(effect_id, p["program"]) : nil
        if draw_op
          # CPU-only draw op (e.g. point-scatter): fresh destination seeds
          # from the prior same-name attachment (accumulator) or clears.
          src_name = (p["inputs"] || {}).keys.sort.map { |k| p["inputs"][k] }.first
          src_name = "inputTex" if src_name.nil?
          src = textures[src_name] || textures["inputTex"] || blank
          result = NoisemakerCpu::Surface.new(width, height)
          prev = out_names.empty? ? nil : attachments[out_names[0]]
          result.data.replace(prev.data) if !prev.nil? && prev.data.length == result.data.length
          draw_op.call(src, result, pass_uniforms)
        else
          ctx = NoisemakerCpu::Ctx.new(
            rt: rt,
            uniforms: pass_uniforms,
            textures: textures,
            resolution: [0.0 + width, 0.0 + height],
            time: time,
            seed: seed,
            blank: blank
          )
          compiled = _kernel_for(p["key"])
          kernel = compiled[:kernel]
          adapter = NoisemakerCpu::Adapters.get_adapter(effect_id, p["program"])
          kernel = adapter.call(rt, compiled) if adapter
          result =
            if compiled[:uses_derivatives]
              NoisemakerCpu::PassRunner.run_pass_deriv(kernel, ctx, width, height)
            else
              NoisemakerCpu::PassRunner.run_pass(kernel, ctx, width, height)
            end
        end
        # Quantize the pass output to its declared texture format.
        NoisemakerCpu::TextureFormat.quantize_texture(result, fmt)
        out_names.each { |name| attachments[name] = result }
      end
      result
    end

    # ---- Polymorphic DSL rendering (port of renderer.py render_dsl tail) ----

    # Turn a compiled surface binding into a Surface (or nil for unbound):
    # '@current' is the chain's current image, ['surface', 'oN'] a named
    # surface that must already have been written.
    def self._resolve_surface_marker(marker, current, surfaces)
      return current if !marker.is_a?(Array) && marker == "@current"

      name = marker[1]
      surf = surfaces[name]
      raise "Surface #{name} has not been written" if surf.nil?

      surf
    end

    # Mirror the JS renderer's per-step binding: the chain's current image is
    # the effect's inputTex; each surface param is bound by param name (the
    # path render_effect resolves), and external textures
    # (imageTex/textTex/named) pass straight through. Explicit surface args
    # and inputTex-defaults win over them.
    def self._run_effect_step(step, current, surfaces, external_textures, width, height, seed, time)
      inputs = (external_textures || {}).dup
      inputs["inputTex"] = current unless current.nil?
      step["surfaces"].keys.sort.each do |pname|
        surf = _resolve_surface_marker(step["surfaces"][pname], current, surfaces)
        inputs[pname] = surf unless surf.nil?
      end
      render_effect(
        step["effect_id"], step["params"], inputs,
        width: width, height: height, seed: seed, time: time
      )
    end

    def self._iteration_step_inputs(step, current, surfaces, external_textures)
      inputs = (external_textures || {}).dup
      inputs["inputTex"] = current unless current.nil?
      (step["surfaces"] || {}).each do |name, marker|
        surface = _resolve_surface_marker(marker, current, surfaces)
        inputs[name] = surface unless surface.nil?
      end
      inputs
    end

    def self._render_iteration_group(group, group_input, surfaces, external_textures, width, height, seed, time)
      owner_step = group["steps"][0]
      owner_inputs = _iteration_step_inputs(owner_step, group_input, surfaces, external_textures)
      owner_state = _initialize_iteration_state(
        owner_step["definition"], owner_step["params"], owner_inputs, seed, width, height
      )
      owner_size = owner_state["params"]["stateSize"] if group["steps"].length > 1
      states = [owner_state]
      group["steps"].drop(1).each do |step|
        inputs = _iteration_step_inputs(step, group_input, surfaces, external_textures)
        states << _initialize_iteration_state(
          step["definition"], step["params"], inputs, seed, width, height, owner_state_size: owner_size
        )
      end

      count = owner_state["params"]["iterationCount"] || 60
      return group_input.clone if count <= 0 && group_input
      return NoisemakerCpu::Surface.new(width, height) if count <= 0

      group_resources = {}
      result = nil
      count.times do |index|
        step_input = group_input
        iteration_time = NoisemakerCpu::Iteration.time_for(time, count, index)
        states.each do |state|
          step_input = _run_iteration_step(
            state, step_input, states: states, group_resources: group_resources,
            width: width, height: height, seed: seed, time: iteration_time, frame: index,
            delta_time: NoisemakerCpu::Iteration::DELTA_TIME
          )
        end
        result = step_input
      end
      result
    end

    # Render a Polymorphic DSL program on the CPU -- the Ruby counterpart of
    # noisemaker-cpu's CpuRenderer.render(). Compiles the program to a plan,
    # then threads each chain's `current` surface through read/write/effect
    # steps over a named-surface map (o0..o7), running one render_effect per
    # effect step.
    def self.render_dsl(source, width: 512, height: 512, seed: 1, time: 0.0, external_textures: nil,
      seed_surfaces: nil)
      surfaces = (seed_surfaces || {}).dup
      plan = NoisemakerCpu::DSL.compile_dsl(source, meta["effects"])
      plan["chains"].each do |chain|
        current = nil
        steps = chain["steps"].map do |step|
          next step unless step["kind"] == "effect"

          step.merge("definition" => meta["effects"].fetch(step["effect_id"]))
        end
        NoisemakerCpu::Iteration.compute_groups(steps).each do |group|
          step = group["steps"][0]
          case step["kind"]
          when "read"
            current = surfaces[step["surface"]]
            raise "Surface #{step['surface']} has not been written" if current.nil?
          when "write"
            surfaces[step["surface"]] = current
          else
            if group["iterated"]
              current = _render_iteration_group(
                group, current, surfaces, external_textures, width, height, seed, time
              )
            else
              group["steps"].each do |effect_step|
                current = _run_effect_step(
                  effect_step, current, surfaces, external_textures, width, height, seed, time
                )
              end
            end
          end
        end
      end
      rendered = surfaces[plan["render_surface"]]
      raise "Surface #{plan['render_surface']} has not been written" if rendered.nil?

      rendered
    end
  end
end
