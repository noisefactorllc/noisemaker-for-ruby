# frozen_string_literal: true

module NoisemakerCpu
  module Iteration
    PARTICLE_STATE_PATTERN = /\Aglobal_(?:xyz|vel|rgba|life_data)\z|\Aglobal_.*_trail\z|\Aglobal_[a-z]+_base_color\z/
    DELTA_TIME = 1.0 / 600

    def self.particle_state_name?(name)
      name.is_a?(String) && PARTICLE_STATE_PATTERN.match?(name)
    end

    def self.wrap01(value)
      ((value % 1) + 1) % 1
    end

    # The built-in surface I/O steps: read/write for images, read3d/write3d for a
    # volume and its geometry.
    def self.surface_io?(step)
      %w[read write read3d write3d].include?(step["kind"])
    end

    def self._animated_image_generator?(step)
      definition = step["definition"] || {}
      definition["kind"] == "generator" && (definition["domain"] || "image") == "image" &&
        definition["iterated"] != true &&
        step["params"].key?("speed") && step["params"]["speed"] != 0
    end

    def self.time_for(render_time, iteration_count, index)
      wrap01(render_time - ((iteration_count - 1 - index) * DELTA_TIME))
    end

    def self.compute_groups(steps)
      groups = []
      open_group = nil
      open_loop = nil
      close_group = lambda do
        next if open_group.nil?

        groups << open_group
        open_group = nil
      end

      steps.each do |step|
        if open_loop
          raise "Loop iteration group cannot cross a read/write boundary" if surface_io?(step)
          raise "Nested loop iteration groups are not supported" if step.dig("definition", "loopRole") == "begin"

          open_loop["steps"] << step
          if step.dig("definition", "loopRole") == "end"
            groups << open_loop
            open_loop = nil
          end
          next
        end
        if surface_io?(step)
          close_group.call
          groups << { "steps" => [step], "iterated" => false }
          next
        end

        definition = step["definition"] || {}
        raise "loopEnd has no matching loopBegin" if definition["loopRole"] == "end"
        if definition["loopRole"] == "begin"
          close_group.call
          open_loop = { "steps" => [step], "iterated" => true, "loop" => true }
          next
        end

        declares_xyz = (definition["textures"] || {}).key?("global_xyz")
        if declares_xyz
          close_group.call
          # The authority renders the whole chain every frame, and pointsEmit colors
          # each agent it spawns from its input at that frame's time. An animated
          # image generator that feeds the group therefore re-runs with it, once per
          # iteration.
          previous = groups.last
          if (step["params"] || {})["iterationCount"].to_f > 0 && previous &&
             previous["steps"].length == 1 && previous["iterated"] != true &&
             _animated_image_generator?(previous["steps"][0])
            groups.pop
            open_group = { "steps" => [previous["steps"][0], step], "iterated" => definition["iterated"] == true }
            next
          end
          open_group = { "steps" => [step], "iterated" => definition["iterated"] == true }
          next
        end

        references_state = (definition["passes"] || []).any? do |pass|
          values = (pass["inputs"] || {}).values + (pass["outputs"] || {}).values
          values.any? { |name| particle_state_name?(name) }
        end
        if open_group && references_state
          open_group["steps"] << step
          next
        end

        # The authority re-runs animated noise3d before every flow3d tick
        # (noisemaker-for-cpu src/runtime/iteration.js): a flow3d step with a
        # positive iterationCount that directly follows a lone synth3d/noise3d
        # step joins it as one iterated group when that noise3d is animated
        # (a `speed` param of 0 keeps both steps independent). `effect_id`
        # carries the id the JS authority stores on `definition.id`, and a
        # missing speed param stays animated, matching the JS `!== 0` check.
        previous = groups.last
        previous_step = previous && previous["steps"][0]
        speed = previous_step && (previous_step["params"] || {})["speed"]
        flow3d_merge = open_group.nil? &&
                       step["effect_id"] == "filter3d/flow3d" &&
                       (step["params"] || {})["iterationCount"].to_f > 0 &&
                       previous_step && previous["steps"].length == 1 &&
                       previous_step["effect_id"] == "synth3d/noise3d" &&
                       !(speed.is_a?(Numeric) && speed.zero?)
        if flow3d_merge
          groups.pop
          groups << { "steps" => [previous["steps"][0], step], "iterated" => true }
          next
        end

        close_group.call
        groups << { "steps" => [step], "iterated" => definition["iterated"] == true }
      end
      raise "loopBegin has no matching loopEnd" if open_loop

      close_group.call
      groups
    end
  end
end
