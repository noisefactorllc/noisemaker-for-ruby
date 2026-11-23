# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu"

# A voxel ray that passes through the edge shared by two cell boundaries
# crosses both at one distance and enters the cell beyond the edge. Whether
# the two crossings compare equal depends on rounding. On the center column
# of an odd-width orthographic frame the ray's x and z crossings are equal at
# every step, so the cell there must show the first face its neighbors leave
# exposed, not the first crossed axis in y, x, z order. A white cliff lit
# only from +z shows this: every face the pixels beside the center column
# show, the center column must show too.
class TestLandscapeEdgeTies < Minitest::Test
  CLIFF = <<~DSL
    search synth, filter, synth3d, render
    gradient(type: linear, color1: #000000, color2: #ffffff).threshold(level: 0.5, sharpness: 1).write(o1)
    solid(color: #ffffff).write(o2)
    heightmap3d(heightTex: read(o1), tex: read(o2), volumeSize: x16, heightScale: 1, baseHeight: 0).renderLandscape3d(lightDirection: vec3(0, 0, 1), ambient: 0, diffuseIntensity: 1, specularIntensity: 0, bgAlpha: 0).write(o0)
    render(o0)
  DSL

  WIDTH = 129
  HEIGHT = 129
  WHITE = [255, 255, 255, 255].freeze

  def test_a_voxel_ray_through_an_edge_shows_the_face_its_neighbors_leave_exposed
    frame = NoisemakerCpu::Renderer.render_dsl(CLIFF, width: WIDTH, height: HEIGHT).to_rgba8
    pixel = lambda do |x, y|
      offset = (y * WIDTH + x) * 4
      frame[offset, 4].unpack("C*")
    end
    middle = (WIDTH - 1) / 2
    face_rows = (0...HEIGHT).select do |y|
      pixel.call(middle - 1, y) == WHITE && pixel.call(middle + 1, y) == WHITE
    end
    assert face_rows.length > 8,
           "the center column must cross lit faces through voxel edges, saw #{face_rows.length} rows"
    off_face = face_rows.reject { |y| pixel.call(middle, y) == WHITE }
    return if off_face.empty?

    y = off_face.first
    assert false,
           "the center column looks at lit faces through voxel edges, and #{off_face.length} of its " \
           "#{face_rows.length} pixels there show #{pixel.call(middle, y).inspect}"
  end
end
