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
    # Regenerated under the oracle's stdlib model: every VECTOR binary op
    # f32-rounds each component at creation (glsl-runtime.js #binary
    # `out[index] = F32(operation(...))`), so the division rounds before the
    # add (0.1f/0.3f -> 0.3333333134651184). The old golden assumed the
    # pre-oracle deferred-rounding model.
    feq @rt.swizzle(chain, "x"), 0.3333333134651184, "chain swizzle x (deferred round)"
    feq @rt.swizzle(chain, "y"), 2.7857143878936768, "chain swizzle y"
    feq @rt.dot(chain, chain), 7.871315956115723, "chain dot"
    feq @rt.length(chain), 2.805586576461792, "chain length (double-rounded)"
  end

  def test_normalize
    veq @rt.normalize(@rt.construct(3, 0.5, 0.5, 1.0)),
        [0.40824827551841736, 0.40824827551841736, 0.8164965510368347], "normalize"
  end

  def test_normalize_divides_by_the_f32_length
    # glsl-runtime normalize divides by length(), F32(sqrt(dot)), and dot is
    # F32(sum): the squared magnitude rounds to f32 before the sqrt. Skipping
    # that inner round moved this shapes3d getNormal vector (repetition on,
    # pixel 0,7) by one ulp per component. Expected values are the oracle's.
    v = @rt.construct(3, -0.0015451312065124512, -0.0015643835067749023, -0.0097536444664001465)
    assert_equal [-0.1545376181602478, -0.15646316111087799, -0.9755191206932068], @rt.normalize(v)
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

  def test_isnan_builtin_is_available
    assert_includes NoisemakerCpu::Runtime::COMPONENT, "isnan"
    assert_equal 1.0, @rt.component_wise("isnan", Float::NAN)
    assert_equal 0.0, @rt.component_wise("isnan", 1.0)
    assert_equal [1.0, 0.0], @rt.component_wise("isnan", [Float::NAN, 0.0])
  end

  def test_int_and_uint_vectors
    u = @rt.construct(3, @rt.i(7), @rt.i(11), @rt.i(4294967295), "uint")
    # uint arithmetic follows the oracle's |0 (ToInt32) emission
    # (canonical-kernels.js e.g. spookyTicker rowSeed), so the wrapped
    # product of 4294967295 * 1664525 surfaces SIGNED (-1664525), not the
    # unsigned >>>0 form (only hashUint32-style helpers >>>0).
    assert_equal [11651675, 18309775, -1664525],
                 @rt.binary("*", u, @rt.construct(3, @rt.i(1664525), "uint"), 3, "uint").to_a,
                 "uvec wrapping multiply"
    assert_equal [4204755366, 1223881804, 1500469937],
                 @rt.pcg3d(@rt.construct(3, @rt.i(1), @rt.i(2), @rt.i(3), "uint")).to_a,
                 "pcg3d via runtime"
    # Regenerated: the oracle's compiled kernels are JavaScript — int-typed
    # `/` is f64 division (testPattern's `digits[i] = temp % 10; temp /= 10;`
    # keeps fractional digits in the canonical kernel), not GLSL truncation.
    assert_equal [-3.5, -2.25],
                 @rt.binary("/", @rt.construct(2, @rt.i(-7), @rt.i(9), "int"),
                                 @rt.construct(2, @rt.i(2), @rt.i(-4), "int"), 2, "int").to_a,
                 "ivec division follows JS f64 semantics"
    assert_equal(-2, @rt.to_int(-2.7), "to_int truncates toward zero")
      # JS `<<` is signed (ToInt32 result): 3 << 30 == -1073741824 in the
    # compiled kernels; >>>0 unsigned forms appear only at explicit helper
    # sites (hashUint32).
    assert_equal(-1073741824, @rt.binary("<<", @rt.i(3), @rt.i(30), 1, "uint"), "uint shift")
  end

  def test_cpu_noise3d_hash4_matches_canonical_javascript_number_semantics
    # Since noisemaker-for-cpu d13b0a2 the canonical hash4 LCG mixing wraps
    # exactly mod 2^32 (cpu_umul / >>> 0) and the final xor chain is unsigned
    # before the f32 snap, so the hash is now in [0, 1). Expected values
    # extracted by executing the real canonicalFactory288 hash4 body from the
    # pinned canonical-kernels.js with seed = 1.
    cases = {
      [0.0, -3.0, 0.0, 1.0] => 0.35828956961631775,
      [0.1, 0.2, 0.3, 0.4] => 0.04977041855454445,
      [-3.0, -3.0, -3.0, 0.0] => 0.4224112033843994,
      [3.0, 3.0, 3.0, 1.0] => 0.28525039553642273,
    }

    cases.each do |point, expected|
      assert_equal expected, @rt.cpu_noise3d_hash4(point, 1), point.inspect
    end
  end

  def test_cpu_perlin_hash3_matches_canonical_javascript_number_semantics
    # synth/perlin's 3D hash3 goes through the same exact-uint rewrite as
    # noise3d's hash4 (compile-glsl restoreUnsignedIntegerArithmetic). Without
    # it the LCG products grow past 2^53 and the gradients come out wrong.
    # Expected values recorded from the pinned canonicalFactory276 hash3
    # while rendering synth/perlin dimensions 3 (seed 1).
    cases = {
      [998.0, 1001.0, 1.0] => 0.57245302200317383,
      [1125.0999755859375, 1128.0999755859375, 128.10000610351562] => 0.45421421527862549,
      [1267.5, 1270.5, 270.5] => 0.46953314542770386,
      [999.0, 1001.0, 1.0] => 0.72455441951751709,
    }

    cases.each do |point, expected|
      assert_equal expected, @rt.cpu_perlin_hash3(point, 1), point.inspect
    end
  end

  def test_cpu_cell3d_hash_result_divides_uint_before_float32_conversion
    q = @rt.construct(3, 504_228_936, 2_080_811_276, 3_539_994_242, "uint")
    assert_equal [0.11739994585514069, 0.48447662591934204, 0.8242191672325134],
                 @rt.cpu_cell3d_hash_result(q)
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

  def test_copy_preserves_vector_array_rows_and_isolates_mutations
    # Mirror of noisemaker-for-cpu 5de2bf8's glsl-runtime.test.js: GLSL array
    # parameters can contain vectors (Dither's builtin palette uniforms are
    # vecN rows), so rt.copy must retain their shape and value semantics and
    # isolate later mutations from the source rows.
    palette = [[0.0, 0.0, 0.0], [1.0, 0.5, 1.0]]
    copied = @rt.copy(palette)
    assert_equal palette, copied
    copied[0][0] = 0.75
    copied[1][1] = 0.25
    assert_equal [0.0, 0.0, 0.0], palette[0]
    assert_equal [1.0, 0.5, 1.0], palette[1]
    veq @rt.copy(@rt.construct(3, 1.0, 2.0, 3.0)), [1.0, 2.0, 3.0], "flat copy"
  end

  # `st = mat2(c, -s, s, c) * st` passes st as both destination and source.
  # Every component must read the original vector: the oracle evaluates the
  # whole product first (python matches it; classicNoisedeck/noise's
  # kaleidoscope rotates by 90 degrees whenever kaleido > 1).
  def test_matrix_mult_assign_reads_an_aliased_source_before_storing
    rotate90 = [0.0, -1.0, 1.0, 0.0] # columns (c, -s), (s, c) with c = 0, s = 1
    st = [1.0, 0.0]
    @rt.matrix_mult_assign(st, rotate90, st, 2)
    assert_equal [0.0, -1.0], st

    src = [1.0, 0.0]
    dst = [9.0, 9.0]
    @rt.matrix_mult_assign(dst, rotate90, src, 2)
    assert_equal [0.0, -1.0], dst
    assert_equal [1.0, 0.0], src, "a distinct source is left unchanged"

    m = [1.0, 2.0, 3.0, 4.0]
    expected = [1.0, 2.0, 3.0, 4.0].dup
    other = [1.0, 2.0, 3.0, 4.0]
    @rt.matrix_mult_assign(expected, other, [1.0, 2.0, 3.0, 4.0], 2)
    @rt.matrix_mult_assign(m, m, m.dup, 2)
    assert_equal expected, m, "an aliased matrix operand is read before it is overwritten"
  end
end
