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
      close_group = lambda do
        next if open_group.nil?

        groups << open_group
        open_group = nil
      end

      steps.each do |step|
        if step["kind"] == "read" || step["kind"] == "write"
          close_group.call
          groups << { "steps" => [step], "iterated" => false }
          next
        end

        definition = step["definition"] || {}
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
      close_group.call
      groups
    end
  end
end
