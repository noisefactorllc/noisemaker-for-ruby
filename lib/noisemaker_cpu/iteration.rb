# frozen_string_literal: true

module NoisemakerCpu
  module Iteration
    PARTICLE_STATE_PATTERN = /\Aglobal_(?:xyz|vel|rgba|life_data)\z|\Aglobal_.*_trail\z/
    DELTA_TIME = 1.0 / 600

    def self.particle_state_name?(name)
      name.is_a?(String) && PARTICLE_STATE_PATTERN.match?(name)
    end

    def self.wrap01(value)
      ((value % 1) + 1) % 1
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
          raise "Loop iteration group cannot cross a read/write boundary" if step["kind"] == "read" || step["kind"] == "write"
          raise "Nested loop iteration groups are not supported" if step.dig("definition", "loopRole") == "begin"

          open_loop["steps"] << step
          if step.dig("definition", "loopRole") == "end"
            groups << open_loop
            open_loop = nil
          end
          next
        end
        if step["kind"] == "read" || step["kind"] == "write"
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

        close_group.call
        groups << { "steps" => [step], "iterated" => definition["iterated"] == true }
      end
      raise "loopBegin has no matching loopEnd" if open_loop

      close_group.call
      groups
    end
  end
end
