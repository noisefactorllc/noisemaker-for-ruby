# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/renderer"

class TestRemap < Minitest::Test
  def render(source)
    NoisemakerCpu::Renderer.render_dsl(source, width: 4, height: 4).to_rgba8
  end

  def test_zone_seven_preserves_authored_bounds_and_polygon_vertices_at_pixel_centers
    black = [0, 0, 0, 255]
    red = [255, 0, 0, 255]
    # These positions straddle the second pixel center but both round to the same f32.
    [["0.3750000001", [black, black, red, red]], ["0.3749999999", [black, red, red, red]]].each do |edge, row|
      source = <<~DSL
        search synth
        solid(color: #f00).write(o1)
        remap(zoneCount: 8, smoothEdge: 0, zone7_count: 4, zone7_tex: read(o1),
          zone7_bounds: [#{edge}, 0, 1, 1], zone7_v0: [#{edge}, 0, 1, 0],
          zone7_v1: [1, 1, #{edge}, 1]).write(o0)
      DSL
      assert_equal row.flatten.pack("C*") * 4, render(source), edge
    end
  end

  def test_feathered_triangle_layers_above_a_translucent_quad_and_background
    source = <<~DSL
      search synth
      solid(color: #f00, alpha: 0.5).write(o1)
      solid(color: #0f0).write(o2)
      remap(bgColor: #00f, bgAlpha: 0.5, smoothEdge: 1, zoneCount: 8,
        zone0_count: 4, zone0_tex: o1, zone0_v0: [0, 0, 1, 0], zone0_v1: [1, 1, 0, 1],
        zone7_count: 3, zone7_tex: o2, zone7_alpha: 0.5,
        zone7_v0: [0, 0, 1, 0], zone7_v1: [0, 0.4, 0, 0]).write(o0)
    DSL
    overlap = [64, 128, 32, 223]
    lower = [128, 0, 64, 191]
    feather = [92, 71, 46, 209]
    assert_equal (overlap * 3 + lower + feather + lower * 11).pack("C*"), render(source)
  end
end
