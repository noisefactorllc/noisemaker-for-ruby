# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/noisemaker_cpu/scatter_adapters"
require_relative "../lib/noisemaker_cpu/surface"

class TestScatterAdapters < Minitest::Test
  FLAT = {
    "density" => 100, "viewMode" => 0, "rotateX" => 0, "rotateY" => 0,
    "rotateZ" => 0, "viewScale" => 1, "posX" => 0, "posY" => 0,
  }.freeze

  def agent_surface(width, height)
    NoisemakerCpu::Surface.new(width, height)
  end

  def poke(surface, x, y, rgba)
    row = surface.height - 1 - y
    surface.data[(row * surface.width + x) * 4, 4] = rgba
  end

  def pixel(surface, row, col)
    surface.data[(row * surface.width + col) * 4, 4]
  end

  def test_point_mapping_and_agent_fetch_follow_gl_row_convention
    assert_nil NoisemakerCpu::ScatterAdapters.scatter_point_pixel(0, 0, 0, 4, 4)
    assert_nil NoisemakerCpu::ScatterAdapters.scatter_point_pixel(Float::NAN, 0, 1, 4, 4)
    assert_equal 24, NoisemakerCpu::ScatterAdapters.scatter_point_pixel(0, 0, 1, 4, 4)

    surface = agent_surface(1, 2)
    poke(surface, 0, 0, [1, 0, 0, 0])
    poke(surface, 0, 1, [0, 1, 0, 0])
    assert_equal [1, 0, 0, 0], NoisemakerCpu::ScatterAdapters.texel_fetch_agent(surface, 0, 0)
    assert_equal [0, 1, 0, 0], NoisemakerCpu::ScatterAdapters.texel_fetch_agent(surface, 0, 1)
  end

  def test_one_pixel_deposit_adapters
    xyz = agent_surface(1, 1)
    vel = agent_surface(1, 1)
    rgba = agent_surface(1, 1)
    poke(xyz, 0, 0, [0.5, 0.5, 0, 1])
    poke(vel, 0, 0, [0, 1, 0, 0])
    poke(rgba, 0, 0, [0.5, 0.25, 1, 0.5])

    destination = agent_surface(4, 4)
    result = NoisemakerCpu::ScatterAdapters.run(
      "points/dla:depositGrid", {}, { "deposit" => 10 },
      { "xyzTex" => xyz, "velTex" => vel, "rgbaTex" => rgba }, destination
    )
    assert_equal 1, result[:pixels]
    assert_equal [0.5, 0.25, 1, 1.0], pixel(destination, 1, 2)

    destination.clear
    NoisemakerCpu::ScatterAdapters.run(
      "points/lenia:deposit", {}, { "depositAmount" => 0.75 }, { "xyzTex" => xyz }, destination
    )
    assert_equal [0.75, 0, 0, 1], pixel(destination, 1, 2)

    destination.clear
    NoisemakerCpu::ScatterAdapters.run(
      "points/physarum:deposit", {}, { "deposit" => 0.5 },
      { "xyzTex" => xyz, "rgbaTex" => rgba }, destination
    )
    assert_equal [0.25, 0.125, 0.5, 0.25], pixel(destination, 1, 2)

    destination.clear
    NoisemakerCpu::ScatterAdapters.run(
      "render/pointsRender:deposit", {}, FLAT, { "xyzTex" => xyz, "rgbaTex" => rgba }, destination
    )
    assert_equal [0.5, 0.25, 1, 0.5], pixel(destination, 1, 2)
  end

  def test_billboard_helpers_and_premultiplied_deposit
    assert_in_delta 0.07695067745562426, NoisemakerCpu::ScatterAdapters.billboard_hash(0, 42), 1e-12
    assert_in_delta 0.9033963931499507, NoisemakerCpu::ScatterAdapters.billboard_hash(1234.5, 42), 1e-12
    assert_equal 1.0, NoisemakerCpu::ScatterAdapters.billboard_shape_alpha(1, 0.5, 0.5)

    xyz = agent_surface(1, 1)
    rgba = agent_surface(1, 1)
    poke(xyz, 0, 0, [0.4375, 0.4375, 0, 1])
    poke(rgba, 0, 0, [0.75, 0.5, 0.25, 1])
    destination = agent_surface(8, 8).clear([0.25, 0.25, 0.25, 0.25])
    uniforms = FLAT.merge(
      "pointSize" => 4, "shapeMode" => 1, "depositOpacity" => 50,
      "sizeVariation" => 0, "rotationVar" => 0, "seed" => 0
    )
    result = NoisemakerCpu::ScatterAdapters.run(
      "render/pointsBillboardRender:deposit",
      { "blend" => ["ONE", "ONE_MINUS_SRC_ALPHA"] }, uniforms,
      { "xyzTex" => xyz, "rgbaTex" => rgba, "spriteTex" => agent_surface(1, 1) }, destination
    )
    assert_operator result[:pixels], :>, 0
    assert_equal [0.5, 0.375, 0.25, 0.625], pixel(destination, 4, 3)
  end

  def test_registry_contains_exact_catalog_keys
    assert_equal %w[
      points/dla:depositGrid points/lenia:deposit points/physarum:deposit
      render/pointsBillboardRender:deposit render/pointsRender:deposit
    ], NoisemakerCpu::ScatterAdapters.keys.sort
  end
end
