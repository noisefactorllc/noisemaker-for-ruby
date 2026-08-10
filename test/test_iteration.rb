# frozen_string_literal: true

require "minitest/autorun"

iteration_path = File.expand_path("../lib/noisemaker_cpu/iteration.rb", __dir__)
require iteration_path if File.exist?(iteration_path)

class TestIteration < Minitest::Test
  def iteration
    return NoisemakerCpu::Iteration if defined?(NoisemakerCpu::Iteration)

    flunk "NoisemakerCpu::Iteration is not implemented"
  end

  def step(id, textures: {}, passes: [], iterated: false)
    {
      "kind" => "effect",
      "effect_id" => id,
      "definition" => {
        "textures" => textures,
        "passes" => passes,
        "iterated" => iterated,
      },
    }
  end

  def test_particle_state_name_contract
    %w[global_xyz global_vel global_rgba global_life_data global_dla_trail].each do |name|
      assert iteration.particle_state_name?(name), name
    end
    refute iteration.particle_state_name?("global_rd_state")
    refute iteration.particle_state_name?("outputTex")
  end

  def test_groups_particle_steps_under_points_emit_owner
    emit = step(
      "render/pointsEmit",
      textures: { "global_xyz" => {} },
      passes: [{ "outputs" => { "outXYZ" => "global_xyz" } }],
      iterated: true
    )
    flock = step(
      "points/flock",
      passes: [{ "inputs" => { "xyzTex" => "global_xyz" }, "outputs" => { "outXYZ" => "global_xyz" } }],
      iterated: true
    )
    solid = step("synth/solid")

    groups = iteration.compute_groups([emit, flock, solid])
    assert_equal [[true, 2], [false, 1]], groups.map { |group| [group["iterated"], group["steps"].length] }
  end

  def test_read_and_write_steps_close_particle_groups
    emit = step(
      "render/pointsEmit",
      textures: { "global_xyz" => {} },
      passes: [{ "outputs" => { "outXYZ" => "global_xyz" } }],
      iterated: true
    )
    read = { "kind" => "read", "surface" => "o0" }
    write = { "kind" => "write", "surface" => "o1" }

    groups = iteration.compute_groups([emit, read, write])
    assert_equal [[true, 1], [false, 1], [false, 1]],
                 groups.map { |group| [group["iterated"], group["steps"].length] }
  end

  def test_iteration_schedule_matches_cpu_reference
    assert_in_delta 1.0 / 600, iteration::DELTA_TIME, 1e-15
    assert_in_delta 0.9966666666666667, iteration.time_for(0.0, 3, 0), 1e-15
    assert_in_delta 0.0, iteration.time_for(0.0, 3, 2), 1e-15
  end
end
