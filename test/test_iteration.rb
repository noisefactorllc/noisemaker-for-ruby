# frozen_string_literal: true

require "minitest/autorun"

iteration_path = File.expand_path("../lib/noisemaker_cpu/iteration.rb", __dir__)
require iteration_path if File.exist?(iteration_path)

class TestIteration < Minitest::Test
  def iteration
    return NoisemakerCpu::Iteration if defined?(NoisemakerCpu::Iteration)

    flunk "NoisemakerCpu::Iteration is not implemented"
  end

  def step(id, textures: {}, passes: [], iterated: false, params: {}, definition: nil)
    {
      "kind" => "effect",
      "effect_id" => id,
      "params" => params,
      "definition" => definition || {
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

  def test_points_emit_merges_a_preceding_animated_image_generator_per_iteration
    emit = step(
      "render/pointsEmit",
      textures: { "global_xyz" => {} },
      passes: [{ "outputs" => { "outXYZ" => "global_xyz" } }],
      iterated: true,
      params: { "iterationCount" => 3 }
    )
    generator = step(
      "synth/perlin",
      params: { "speed" => 0.25 },
      # PointsEmit (kind: "points") declares global_xyz, so an animated image
      # generator before it joins the loop group and re-runs each iteration
      # (upstream isAnimatedImageGenerator + runIterationGroupSync).
      definition: {
        "kind" => "generator",
        "domain" => "image",
        "iterated" => false,
      }
    )

    groups = iteration.compute_groups([generator, emit])
    assert_equal [[true, 2]], groups.map { |group| [group["iterated"], group["steps"].length] }
    assert_equal generator, groups[0]["steps"][0]
    assert_equal emit, groups[0]["steps"][1]
  end

  def test_a_static_or_speed_zero_generator_before_points_emit_stays_outside_the_group
    emit = step(
      "render/pointsEmit",
      textures: { "global_xyz" => {} },
      passes: [{ "outputs" => { "outXYZ" => "global_xyz" } }],
      iterated: true,
      params: { "iterationCount" => 3 }
    )
    static = step("synth/perlin", params: {}, definition: { "kind" => "generator", "domain" => "image" })
    stopped = step(
      "synth/perlin", params: { "speed" => 0 }, definition: { "kind" => "generator", "domain" => "image" }
    )
    points_kind = step(
      "synth/perlin", params: { "speed" => 0.5 }, definition: { "kind" => "points", "domain" => "image" }
    )
    volume_kind = step(
      "synth/perlin", params: { "speed" => 0.5 }, definition: { "kind" => "generator", "domain" => "volume" }
    )

    %w[static stopped points_kind volume_kind].each do |name|
      input = binding.local_variable_get(name)
      assert_equal [[false, 1], [true, 1]],
        iteration.compute_groups([input, emit]).map { |g| [g["iterated"], g["steps"].length] }, name
    end
  end

  def test_flow3d_reruns_animated_noise3d_per_tick
    flow = step("filter3d/flow3d", iterated: true, params: { "iterationCount" => 2 })
    animated = step("synth3d/noise3d", params: { "speed" => 1 })
    static_noise = step("synth3d/noise3d", params: { "speed" => 0 })
    zero_flow = step("filter3d/flow3d", iterated: true, params: { "iterationCount" => 0 })

    groups = iteration.compute_groups([animated, flow])
    assert_equal [[true, 2]], groups.map { |group| [group["iterated"], group["steps"].length] }
    groups = iteration.compute_groups([static_noise, flow])
    assert_equal [[false, 1], [true, 1]],
                 groups.map { |group| [group["iterated"], group["steps"].length] }
    groups = iteration.compute_groups([animated, zero_flow])
    assert_equal [[false, 1], [true, 1]],
                 groups.map { |group| [group["iterated"], group["steps"].length] }
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

  def test_balanced_loop_region_forms_one_iteration_group
    solid = step("synth/solid")
    loop_begin = step("render/loopBegin", iterated: true)
    loop_begin["definition"]["loopRole"] = "begin"
    blur = step("filter/blur")
    loop_end = step("render/loopEnd")
    loop_end["definition"]["loopRole"] = "end"
    invert = step("filter/invert")

    groups = iteration.compute_groups([solid, loop_begin, blur, loop_end, invert])

    assert_equal [
      [false, false, 1],
      [true, true, 3],
      [false, false, 1],
    ], groups.map { |group| [group["iterated"], group["loop"] == true, group["steps"].length] }
  end
end
