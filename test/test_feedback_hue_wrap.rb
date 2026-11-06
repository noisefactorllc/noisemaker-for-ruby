# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/runtime"

# Upstream 8395d1da made the effects' hsv2rgb take its last sector as the else
# branch, and 6f98d26a wrapped that sector across the 18 effects that share the
# helper. fract() returns 1.0 for a hue just below a whole number, and a
# compiler that folds hsv2rgb's own fract() into the caller's fract() reaches
# the sector chain with the raw h = 1.0. The pinned GLSL wraps that h through
# the last sector — rgb = (c, 0, x), the colour of h = 0.0 — instead of
# falling into a black vec3(0). The rendered pipeline always applies fract()
# before the call, so no render reaches h >= 1.0; these checks evaluate the
# vendored feedback kernel's own hsv2rgb directly, plus the source shape that
# keeps a folded-compiler h = 1.0 on the wrap path.
class TestFeedbackHueWrap < Minitest::Test
  KERNEL = File.expand_path(
    "../lib/noisemaker_cpu/bundle/kernels/ruby/filter__feedback__feedback.rb", __dir__
  ).freeze
  BLACK_FALLBACK = "rgb[0] = rt.f32(rt.f(0)); rgb[1] = rt.f32(rt.f(0)); rgb[2] = rt.f32(rt.f(0))"

  def extract_hsv2rgb_source
    src = File.read(KERNEL)
    start = src.index("hsv2rgb__vec3 = lambda do |hsv|")
    raise "the feedback kernel does not define hsv2rgb" unless start

    stop = src.index(/\n  [a-z]\w*__\w+ = /, start + 8)
    raise "the feedback kernel's hsv2rgb has no following helper" unless stop

    src[start...stop]
  end

  def hsv2rgb
    rt = NoisemakerCpu::Runtime.new
    eval(extract_hsv2rgb_source + "\nhsv2rgb__vec3", binding, "feedback-hue-wrap") # rubocop:disable Security/Eval -- generated kernel probe
  end

  def vec3(*components)
    components.map { |c| NoisemakerCpu::Runtime.new.f32(c) }
  end

  def test_the_vendored_hsv2rgb_has_no_black_fallback_sector
    refute_includes extract_hsv2rgb_source, BLACK_FALLBACK,
                    "the old black vec3(0) fallback sector is gone"
  end

  def test_h_1_renders_as_h_0_not_black
    hsv = hsv2rgb
    assert_equal hsv.call(vec3(0, 1, 1)), hsv.call(vec3(1, 1, 1))
    assert_equal [1.0, 0.0, 0.0], hsv.call(vec3(1, 1, 1))
  end

  def test_h_1_25_wraps_to_h_0_25
    hsv = hsv2rgb
    assert_equal hsv.call(vec3(0.25, 1, 1)), hsv.call(vec3(1.25, 1, 1))
  end

  def test_every_h_in_minus_1_to_2_wraps_to_its_fract_colour
    hsv = hsv2rgb
    rt = NoisemakerCpu::Runtime.new
    # Steps of 1/256 are exact in float32 and their fract() wrap is exact too,
    # so the wrapped and unwrapped calls must agree bit for bit.
    (-256...512).each do |step|
      h = rt.f32(step / 256.0)
      wrapped = hsv.call(vec3(h, 0.75, 1))
      unwrapped = hsv.call(vec3(rt.component_wise("fract", h), 0.75, 1))
      assert_equal unwrapped, wrapped, "h = #{h}"
    end
  end
end
