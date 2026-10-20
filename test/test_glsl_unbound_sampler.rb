# frozen_string_literal: true

# Port of noisemaker-for-cpu test/glsl-unbound-sampler.test.js, adapted to the
# Ruby API. Mirrors upstream be8ed4cd: a declared sampler that the pass lists
# no input for reads transparent black (the backends bind their default
# texture), and a binding that exists but is not a Surface stays an error.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/runtime"

class TestGlslUnboundSampler < Minitest::Test
  def test_an_unbound_sampler_reads_transparent_black
    rt = NoisemakerCpu::Runtime.new
    rt.begin_pixel
    assert_equal [0.0, 0.0, 0.0, 0.0], rt.texture(nil, [0.25, 0.75])
    assert_equal [0.0, 0.0, 0.0, 0.0], rt.texel_fetch(nil, [0, 0])
  end

  def test_a_non_surface_sampler_binding_still_fails
    rt = NoisemakerCpu::Runtime.new
    rt.begin_pixel
    assert_raises(TypeError) { rt.texture(Object.new, [0.25, 0.75]) }
    assert_raises(TypeError) { rt.texel_fetch(Object.new, [0, 0]) }
  end
end
