# frozen_string_literal: true

# Mirror of t/03-runtime.t (Perl), assertion-for-assertion. Goldens
# generated from the Python runtime (167/167 parity-proven), copied
# verbatim from the Perl test.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/runtime"

class TestRuntime < Minitest::Test
  def setup
    @rt = NoisemakerCpu::Runtime.new
  end

  def feq(got, want, msg = nil)
    assert_operator (got - want).abs, :<=, (want.abs * 1e-12) + 1e-12, msg
  end

  def veq(got, want, msg = nil)
    assert_equal want.length, got.length, "#{msg} width"
    want.each_index { |idx| feq got[idx], want[idx], "#{msg} [#{idx}]" }
  end

  def test_deferred_rounding_chain
    # Deferred rounding: the compound (a/b + c) rounds ONCE at the boundary.
    a = @rt.construct(2, 0.1, 0.2)
    b = @rt.construct(2, 0.3, 0.7)
    c = @rt.construct(2, 1e-8, 2.5)
    chain = @rt.binary("+", @rt.binary("/", a, b, 2, "float"), c, 2, "float")
    feq @rt.swizzle(chain, "x"), 0.3333333432674408, "chain swizzle x (deferred round)"
    feq @rt.swizzle(chain, "y"), 2.7857143878936768, "chain swizzle y"
    feq @rt.dot(chain, chain), 7.871315956115723, "chain dot"
    feq @rt.length(chain), 2.805586576461792, "chain length (double-rounded)"
  end

  def test_normalize
    veq @rt.normalize(@rt.construct(3, 0.5, 0.5, 1.0)),
        [0.40824827551841736, 0.40824827551841736, 0.8164965510368347], "normalize"
  end

  def test_component_wise_builtins
    a = @rt.construct(2, 0.1, 0.2)
    b = @rt.construct(2, 0.3, 0.7)

    veq @rt.component_wise("mix", a, b, @rt.f(0.3)),
        [0.1600000113248825, 0.3499999940395355], "mix"
    feq @rt.component_wise("smoothstep", @rt.f(0.2), @rt.f(0.8), @rt.f(0.5)),
        0.4999999701976776, "smoothstep"
    feq @rt.component_wise("smoothstep", @rt.f(0.5), @rt.f(0.5), @rt.f(0.7)),
        1.0, "smoothstep zero-width band (IEEE inf -> clamp)"
    feq @rt.component_wise("mod", @rt.f(-1.3), @rt.f(1.0)), 0.7000000476837158, "glsl mod"
    feq @rt.component_wise("pow", @rt.f(2.0), @rt.f(0.5)), 1.4142135381698608, "pow"
    veq @rt.component_wise("fract", @rt.binary("*", a, @rt.f(7.3), 2, "float")),
        [0.7300000190734863, 0.46000003814697266], "fract of deferred product"
    veq @rt.component_wise("step", @rt.f(0.15), a), [0.0, 1.0], "step"
    veq @rt.component_wise("clamp", @rt.construct(2, -0.5, 1.5), @rt.f(0.0), @rt.f(1.0)),
        [0.0, 1.0], "clamp"
    feq @rt.component_wise("atan", @rt.f(1.0), @rt.f(2.0)), 0.46364760398864746, "atan2"
  end

  def test_int_and_uint_vectors
    u = @rt.construct(3, @rt.i(7), @rt.i(11), @rt.i(4294967295), "uint")
    assert_equal [11651675, 18309775, 4293302771],
                 @rt.binary("*", u, @rt.construct(3, @rt.i(1664525), "uint"), 3, "uint").to_a,
                 "uvec wrapping multiply"
    assert_equal [4204755366, 1223881804, 1500469937],
                 @rt.pcg3d(@rt.construct(3, @rt.i(1), @rt.i(2), @rt.i(3), "uint")).to_a,
                 "pcg3d via runtime"
    assert_equal [-3, -2],
                 @rt.binary("/", @rt.construct(2, @rt.i(-7), @rt.i(9), "int"),
                                 @rt.construct(2, @rt.i(2), @rt.i(-4), "int"), 2, "int").to_a,
                 "ivec division truncates toward zero"
    assert_equal(-2, @rt.to_int(-2.7), "to_int truncates toward zero")
    assert_equal 3221225472, @rt.binary("<<", @rt.i(3), @rt.i(30), 1, "uint"), "uint shift"
  end

  def test_ivec_swizzle
    iv = @rt.construct(3, @rt.i(5), @rt.i(6), @rt.i(7), "int")
    assert_equal 7, @rt.swizzle(iv, "z"), "ivec swizzle scalar stays int"
    sub = @rt.swizzle(iv, "xy")
    assert_equal NoisemakerCpu::Runtime::IVec, sub.class, "ivec swizzle stays IVec"
    assert_equal [5, 6], sub.to_a, "ivec swizzle values"
  end

  def test_assign_swizzle_copy_on_write
    v0 = @rt.construct(3, 1.0, 2.0, 3.0)
    v1 = @rt.assign_swizzle(v0, "xz", @rt.construct(2, 9.0, 8.0))
    assert_equal [1.0, 2.0, 3.0], v0, "assign_swizzle leaves source untouched"
    assert_equal [9.0, 2.0, 8.0], v1, "assign_swizzle result"
  end

  def test_matrices_reflect_refract
    veq @rt.matrix_mult(@rt.construct(4, 1.0, 2.0, 3.0, 4.0), @rt.construct(2, 5.0, 6.0), 2),
        [23.0, 34.0], "mat2 * vec2"
    veq @rt.matrix_mult(@rt.construct(4, 1.0, 2.0, 3.0, 4.0),
                         @rt.construct(4, 7.0, 8.0, 9.0, 10.0), 2),
        [31.0, 46.0, 39.0, 58.0], "mat2 * mat2 (column-major)"
    veq @rt.reflect(@rt.construct(2, 1.0, -1.0), @rt.construct(2, 0.0, 1.0)), [1.0, 1.0], "reflect"
    veq @rt.refract(@rt.construct(2, 0.0, -1.0), @rt.construct(2, 0.0, 1.0), @rt.f(0.9)),
        [0.0, -1.0], "refract"
  end

  def test_bits_and_half
    assert_equal 1060320051, @rt.float_bits_to_uint(0.7), "float_bits_to_uint"
    assert_equal 3271570432, @rt.pack_half_2x16(@rt.construct(2, 0.25, -3.5)), "pack_half_2x16"
  end

  def test_stdlib_override_hook
    @rt.stdlib_override["sin"] = ->(*_args) { 42.0 }
    assert_equal 42.0, @rt.component_wise("sin", @rt.f(1.0)), "stdlib_override wins"
    @rt.stdlib_override.delete("sin")
  end

  def test_derivatives_record_replay_basics
    @rt.deriv_reset("record")
    z = @rt.dFdx(1.5)
    assert_equal 0.0, z, "record mode returns zero"
    assert_equal ["dFdx", 1.5], @rt.deriv_log[0], "record captured op+value"
    @rt.deriv_reset("replay", [{ "dFdx" => 0.25, "dFdy" => 0.5, "fwidth" => 0.75 }])
    assert_equal 0.25, @rt.dFdx(1.5), "replay returns fine diff"
    @rt.deriv_reset(nil)
  end

  # --- review regression goldens (python-verified) ---

  def test_negative_int_shift_regressions
    # negative int >> is ARITHMETIC (Perl's raw >> on negative IVs is logical-64)
    assert_equal(-2, @rt.binary(">>", -8, 2, 1, "int"), "negative int >> arithmetic")
    assert_equal(-1, @rt.binary(">>", -1, 31, 1, "int"), "int -1 >> 31 stays -1")
  end

  def test_huge_float_wrap_regressions
    # huge floats WRAP mod 2**32 (Perl int() saturates past IV_MAX)
    assert_equal 1661992960, @rt.to_uint(1e20), "to_uint(1e20) wraps like JS >>> 0"
    assert_equal(-1661992960, @rt.to_int(-1e20), "to_int(-1e20) wraps signed")
  end

  def test_nan_propagation_regressions
    # NaN propagation through min/max/clamp/sign (numpy semantics)
    qnan = Float::NAN
    mn = @rt.component_wise("min", @rt.f(1.0), qnan)
    assert mn.nan?, "min(1, NaN) is NaN"
    sg = @rt.component_wise("sign", qnan)
    assert sg.nan?, "sign(NaN) is NaN"
  end

  def test_deriv_record_snaps_to_f32
    # deriv record snaps raw deferred-f64 vectors to f32 (Float32Array semantics)
    @rt.deriv_reset("record")
    rawv = @rt.binary("/", @rt.construct(2, 0.1, 0.2), @rt.construct(2, 0.3, 0.7), 2, "float")
    @rt.dFdx(rawv)
    rec = @rt.deriv_log[0][1]
    feq rec[0], 0.3333333134651184, "deriv record snaps [0]"
    feq rec[1], 0.2857142984867096, "deriv record snaps [1]"
    @rt.deriv_reset(nil)
  end

  def test_fdiv_negative_zero_denominator
    # fdiv honors negative-zero denominators
    assert_equal(-Float::INFINITY, NoisemakerCpu::UintMath.fdiv(5.0, -0.0), "fdiv(5, -0.0) = -Inf")
  end
end
