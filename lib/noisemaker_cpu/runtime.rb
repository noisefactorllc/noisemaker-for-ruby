# frozen_string_literal: true

# CSL/GLSL CPU runtime -- the vector-math core that transpiled kernels call.
#
# Faithful port of the (parity-proven) Perl runtime
# (lib/Math/Fractal/Noisemaker/Runtime.pm), itself a port of noisemaker-cpu
# src/csl/runtime.js + glsl-runtime.js semantics. The float model that
# achieved 167/167 byte-parity is baked in:
#
# - Scalars are Ruby Floats (float64). Scalar arithmetic accumulates raw f64,
#   rounded to float32 only at boundaries.
# - Vectors are plain Ruby Arrays. binary/unary DEFER float32 rounding (raw
#   f64 element math), and every consumption boundary -- swizzle, dot,
#   component_wise, assign_swizzle, texture, construct, the output stage --
#   snaps to f32. This mirrors JS, which evaluates a whole component
#   expression in float64 and rounds once when storing into a Float32Array.
#   Per-op rounding double-rounds and accumulates sub-ULP error (the bug
#   that broke wormhole in the Python port until fixed).
# - Integer vectors are Arrays of the IVec subclass so int-ness survives
#   swizzles and copies (uvec hash seeds keep full precision).
# - float32 rounding is pack('e')/unpack('e') (explicit little-endian; see
#   uint_math.rb header and contract trap #4 -- Ruby has no native float32).
# - Screen-space derivatives use the FINE 2x2-quad record/replay model.
#
# Integration note for Worker C (pass_runner.rb, NOT part of this file):
# Perl's Renderer.pm constructs the runtime with NO arguments
# (`Math::Fractal::Noisemaker::Runtime->new`) once per render, then hands it
# to `Math::Fractal::Noisemaker::Ctx->new(rt => $rt, ...)` (defined inside
# PassRunner.pm), which stores it as `$ctx->{rt}`; kernels read it back via
# `ctx.rt` per the kernel ABI. `NoisemakerCpu::Runtime.new` mirrors this
# exactly: zero required arguments. Ruby's `stdlib_override` is exposed via
# an `attr_reader` (a mutable String-keyed Hash), since Perl's tests mutate
# it as `$rt->{stdlib_override}{name} = sub {...}` (direct blessed-hashref
# access) -- there is no `stdlib_override=` writer, only in-place mutation
# of the Hash `rt.stdlib_override` returns, exactly matching Perl's
# in-place-hash-mutation usage in t/03-runtime.t.

require_relative "uint_math"
require_relative "sampler"

module NoisemakerCpu
  class Runtime
    # Blessed-arrayref-into-IVec equivalent: a plain Array subclass marking
    # an integer (ivec/uvec) vector so int-ness survives swizzles/copies.
    class IVec < Array
    end

    U32 = 0xFFFFFFFF
    INF = Float::INFINITY
    NAN = Float::NAN
    PI = 3.141592653589793

    # ---- private numeric helpers referenced by the COMPONENT dispatch
    # table (see far below). These are plain functions of their arguments
    # in Perl too (no $self) -- implemented here as Runtime class methods
    # (not instance methods) both for that structural parity and because a
    # frozen dispatch Hash of Method objects must be built once, at
    # class-load time, before any instance exists.

    def self._sign(x)
      return x if x.is_a?(Float) && x.nan?

      x > 0 ? 1.0 : (x < 0 ? -1.0 : 0.0)
    end

    # Ruby's native Math.sqrt/Math.log/Math.log2/Math.asin/Math.acos raise
    # Math::DomainError for out-of-domain input; Perl's POSIX:: equivalents
    # (like JS Math.*) silently return NaN. This is NOT one of the
    # contract's enumerated traps -- discovered and verified empirically
    # (see worker report) -- and is guarded at every domain-restricted
    # transcendental below, not just sqrt/log (whose guards Perl already
    # names `_safe_sqrt`/`_safe_log`).
    def self._safe_sqrt(x)
      return NAN if (x.is_a?(Float) && x.nan?) || x < 0

      Math.sqrt(x)
    end

    def self._safe_log(x)
      return NAN if (x.is_a?(Float) && x.nan?) || x < 0
      return -INF if x == 0

      Math.log(x)
    end

    # Not in Perl's Runtime.pm under this name (POSIX::log2 never raises,
    # so Perl's `log2` table entry has no guard) -- added because Ruby's
    # Math.log2 raises Math::DomainError on negative input.
    def self._safe_log2(x)
      return NAN if (x.is_a?(Float) && x.nan?) || x < 0
      return -INF if x == 0

      Math.log2(x)
    end

    # Added for the same reason as _safe_log2: Ruby's Math.asin/Math.acos
    # raise Math::DomainError outside [-1, 1]; Perl's POSIX::asin/acos (like
    # JS Math.asin/acos) return NaN.
    def self._safe_asin(x)
      return NAN if (x.is_a?(Float) && x.nan?) || x < -1 || x > 1

      Math.asin(x)
    end

    def self._safe_acos(x)
      return NAN if (x.is_a?(Float) && x.nan?) || x < -1 || x > 1

      Math.acos(x)
    end

    def self._nmin(a, b)
      return NAN if (a.is_a?(Float) && a.nan?) || (b.is_a?(Float) && b.nan?)

      a < b ? a : b
    end

    def self._nmax(a, b)
      return NAN if (a.is_a?(Float) && a.nan?) || (b.is_a?(Float) && b.nan?)

      a > b ? a : b
    end

    # Perl wraps `$x**$y` in `eval` and falls back to NaN if it dies. Ruby's
    # `**` has no Perl/JS/C analog for domain errors -- it instead returns a
    # Complex for a negative base with a non-integer exponent (e.g.
    # `(-1.0) ** 0.5 == (0.0+1.0i)`), which is NOT one of the contract's
    # traps and would silently poison every downstream float op with a
    # Complex value. Verified empirically (see worker report); guarded by
    # replicating C pow()/JS Math.pow's domain rule directly: negative base
    # with a non-integer, finite exponent is NaN, matching perl/JS pow.
    def self._pow(x, y)
      return NAN if (x.is_a?(Float) && x.nan?) || (y.is_a?(Float) && y.nan?)

      xf = x.to_f
      yf = y.to_f
      return NAN if xf < 0 && yf.finite? && yf != yf.to_i

      r = xf**yf
      r.is_a?(Float) ? r : NAN
    rescue StandardError
      NAN
    end

    def self._clampf(x, lo, hi)
      _nmin(_nmax(x, lo), hi)
    end

    def self._mixf(a, b, t)
      a * (1.0 - t) + b * t
    end

    def self._smoothstepf(e0, e1, x)
      # IEEE zero-width band: e0==e1 yields nan/inf like JS, clamp resolves it.
      t = _clampf(NoisemakerCpu::UintMath.fdiv(x - e0, e1 - e0), 0.0, 1.0)
      t * t * (3.0 - 2.0 * t)
    end

    def self._glsl_modf(x, y)
      q = NoisemakerCpu::UintMath.fdiv(x, y)
      return NAN if q.is_a?(Float) && q.nan?

      x - y * _safe_floor(q)
    end

    # Perl POSIX::floor/ceil/trunc (like JS Math.floor/ceil/trunc) propagate
    # NaN/Infinity unchanged; Ruby's native Float#floor/#ceil/#truncate all
    # raise FloatDomainError on non-finite input (verified empirically; not
    # one of the contract's enumerated traps). Guarded here, once, and
    # reused by the COMPONENT table AND by _glsl_modf above.
    def self._safe_floor(x)
      return x if x.is_a?(Float) && !x.finite?
      return x if x == 0 # preserve -0.0 sign (Integer#floor.to_f loses it)

      x.floor.to_f
    end

    def self._safe_ceil(x)
      return x if x.is_a?(Float) && !x.finite?
      return x if x == 0

      x.ceil.to_f
    end

    def self._safe_trunc(x)
      return x if x.is_a?(Float) && !x.finite?
      return x if x == 0

      x.truncate.to_f
    end

    # ---- component-wise / relational dispatch tables (file-scope lexicals
    # in Perl; class constants here -- shared across all instances either
    # way). Must be defined after the helper class methods above (Ruby
    # evaluates class bodies top-to-bottom; `method(:_foo)` needs `_foo` to
    # already exist).

    COMPONENT = {
      "abs" => ->(x) { x.abs },
      "floor" => method(:_safe_floor),
      "ceil" => method(:_safe_ceil),
      "fract" => ->(x) { x - _safe_floor(x) },
      "sign" => method(:_sign),
      "sqrt" => method(:_safe_sqrt),
      "inversesqrt" => ->(x) { NoisemakerCpu::UintMath.fdiv(1.0, _safe_sqrt(x)) },
      "sin" => ->(x) { Math.sin(x) },
      "cos" => ->(x) { Math.cos(x) },
      "tan" => ->(x) { Math.tan(x) },
      "asin" => method(:_safe_asin),
      "acos" => method(:_safe_acos),
      "atan" => ->(x) { Math.atan(x) }, # native libm atan, matching Math.atan/np.arctan
      "sinh" => ->(x) { Math.sinh(x) },
      "cosh" => ->(x) { Math.cosh(x) },
      "tanh" => ->(x) { Math.tanh(x) },
      "exp" => ->(x) { Math.exp(x) },
      "log" => method(:_safe_log),
      "exp2" => ->(x) { 2**x }, # the JS oracle uses Math.pow(2, x) too; base is always positive so no Complex risk
      "log2" => method(:_safe_log2),
      "radians" => ->(x) { x * (PI / 180.0) },
      "degrees" => ->(x) { x * (180.0 / PI) },
      "min" => method(:_nmin),
      "max" => method(:_nmax),
      "pow" => method(:_pow),
      "clamp" => method(:_clampf),
      "mix" => method(:_mixf),
      "step" => ->(edge, x) { x < edge ? 0.0 : 1.0 },
      "smoothstep" => method(:_smoothstepf),
      "mod" => method(:_glsl_modf),
      "trunc" => method(:_safe_trunc),
      "round" => ->(x) { _safe_floor(x + 0.5) },
    }.freeze

    RELATIONAL = {
      "lessThan" => ->(a, b) { a < b ? 1 : 0 },
      "lessThanEqual" => ->(a, b) { a <= b ? 1 : 0 },
      "greaterThan" => ->(a, b) { a > b ? 1 : 0 },
      "greaterThanEqual" => ->(a, b) { a >= b ? 1 : 0 },
      "equal" => ->(a, b) { a == b ? 1 : 0 },
      "notEqual" => ->(a, b) { a != b ? 1 : 0 },
    }.freeze

    SWIZZLE = {
      "x" => 0, "y" => 1, "z" => 2, "w" => 3,
      "r" => 0, "g" => 1, "b" => 2, "a" => 3,
      "s" => 0, "t" => 1, "p" => 2, "q" => 3,
    }.freeze

    # ---- construction ----

    def initialize
      @deriv_mode = nil # nil | 'record' | 'replay'
      @deriv_log = []
      @deriv_diffs = nil
      @deriv_i = 0
      # Per-render stdlib overrides (CPU adapters replace e.g. sin with a
      # range-reduced variant): name -> callable(*args) returning the value.
      @stdlib_override = {}
    end

    attr_reader :stdlib_override

    def begin_pixel(*); end

    # Every condition context the codegen emits (if/while/ternary/&&/||/!)
    # goes through this (contract trap #1): Integer 0 is truthy in Ruby,
    # unlike Perl, so a bare `if glsl_bool_value` would be wrong wherever
    # the value happens to be 0.
    def bool(x)
      x != 0
    end

    # ---- screen-space derivatives (2x2-quad record/replay) ----

    def deriv_reset(mode, diffs = nil)
      @deriv_mode = mode
      @deriv_i = 0
      @deriv_log = []
      @deriv_diffs = diffs
    end

    def deriv_log
      @deriv_log
    end

    def dFdx(v)
      _deriv("dFdx", v)
    end

    def dFdy(v)
      _deriv("dFdy", v)
    end

    def fwidth(v)
      _deriv("fwidth", v)
    end

    # Per-pixel FINE screen-space derivatives, matching the reference
    # engine's wrapDerivatives: dFdx uses the pixel's own row (chosen by
    # y-parity), dFdy its own column (x-parity). `lanes` are the 4 recorded
    # quad-corner logs in [LL, LR, UL, UR] order (lower/upper x left/right,
    # bottom-left space).
    def deriv_fine(lanes, x_parity, y_parity)
      left = lanes[y_parity * 2]
      right = lanes[(y_parity * 2) + 1]
      bottom = lanes[x_parity]
      top = lanes[x_parity + 2]
      n = 0
      [left, right, bottom, top].each { |l| n = l.length if l.length > n }
      diffs = []
      (0...n).each do |i|
        lv = i < left.length ? left[i][1] : 0.0
        rv = i < right.length ? right[i][1] : lv
        bv = i < bottom.length ? bottom[i][1] : 0.0
        tv = i < top.length ? top[i][1] : bv
        xd = nil
        yd = nil
        wd = nil
        if !_is_vec(lv) && !_is_vec(rv) && !_is_vec(bv) && !_is_vec(tv)
          xd = f32(rv - lv)
          yd = f32(tv - bv)
          wd = f32(xd.abs + yd.abs)
        else
          w = 0
          [lv, rv, bv, tv].each { |v| w = v.length if _is_vec(v) && v.length > w }
          xdv = []
          ydv = []
          wdv = []
          (0...w).each do |k|
            l = _is_vec(lv) ? lv[k] : lv
            r = _is_vec(rv) ? rv[k] : rv
            b = _is_vec(bv) ? bv[k] : bv
            t = _is_vec(tv) ? tv[k] : tv
            x = f32(r - l)
            y = f32(t - b)
            xdv << x
            ydv << y
            wdv << f32(x.abs + y.abs)
          end
          xd = xdv
          yd = ydv
          wd = wdv
        end
        diffs << { "dFdx" => xd, "dFdy" => yd, "fwidth" => wd }
      end
      diffs
    end

    # ---- literals ----

    def f(x) # float literal
      f32(x)
    end

    def i(x) # int literal
      x.to_i
    end

    # Callable both as the kernel-facing method rt.f32(x) and (bare, from
    # other instance methods below) as a plain scalar helper -- Perl needs
    # a `ref $_[0] ? ...` dual-mode trick for this; a single Ruby instance
    # method naturally serves both call shapes.
    def f32(x)
      [x].pack("e").unpack1("e")
    end

    # ---- construction of vectors ----

    # Build a vecN (width>1) or scalar (width==1) from scalars/vectors. One
    # scalar arg splats. Otherwise components are flattened in order and
    # truncated to exactly `width`. base int/uint builds an IVec (values
    # kept exact, not float32-rounded).
    def construct(width, *rest)
      # The codegen appends the base tag ('int'/'uint') as a literal
      # trailing string argument only for integer constructs; floats pass
      # no tag.
      base = "float"
      if !rest.empty? && !rest[-1].nil? && rest[-1].is_a?(String) && (rest[-1] == "int" || rest[-1] == "uint")
        base = rest.pop
      end
      supplied = rest.compact
      if base == "int" || base == "uint"
        # Truncate-and-wrap via u32 (Ruby Integers never overflow, unlike
        # Perl's IV_MAX-saturating int() -- see uint_math.rb); _s32 restores
        # the sign for int.
        wrap = if base == "uint"
                 ->(v) { NoisemakerCpu::UintMath.u32(v) }
               else
                 ->(v) { _s32(NoisemakerCpu::UintMath.u32(v)) }
               end
        if supplied.length == 1 && !_is_vec(supplied[0]) && width > 1
          iv = wrap.call(supplied[0])
          return IVec.new(Array.new(width, iv))
        end
        ivals = []
        supplied.each do |c|
          if _is_vec(c)
            c.each { |e| ivals << wrap.call(e) }
          else
            ivals << wrap.call(c)
          end
        end
        return ivals[0] if width == 1

        return IVec.new(ivals[0...width])
      end
      if width == 1
        c = supplied[0]
        raise "construct(1) requires a component" if c.nil?

        return f32(_is_vec(c) ? c[0] : c)
      end
      if supplied.length == 1 && !_is_vec(supplied[0])
        v = f32(supplied[0])
        return Array.new(width, v)
      end
      vals = []
      supplied.each do |c|
        if _is_vec(c)
          c.each { |e| vals << f32(e) }
        else
          vals << f32(c)
        end
      end
      raise "construct(#{width}) with no components" if vals.empty?
      if vals.length < width # pad by repeating last (defensive)
        vals += [vals[-1]] * (width - vals.length)
      end
      vals[0...width]
    end

    # Pass-by-value copy of a function argument, coerced to the DECLARED
    # parameter's element type. Float params force float32 (GLSL implicit
    # conversion at the call boundary); int/uint params stay integer so a
    # uvecN hash seed keeps full precision.
    def copy(vec, base = nil)
      return f32(vec) unless _is_vec(vec)
      return IVec.new(vec.map(&:to_i)) if base == "int" || base == "uint"

      vec.map { |c| f32(c) }
    end

    # ---- swizzles ----

    def swizzle(vec, sw)
      idx = sw.chars.map { |c| SWIZZLE[c] }
      if _is_ivec(vec)
        return vec[idx[0]].to_i if idx.length == 1

        return IVec.new(idx.map { |j| vec[j] })
      end
      # JS reads a stored f32 element (binary defers the round).
      return f32(vec[idx[0]]) if idx.length == 1

      idx.map { |j| f32(vec[j]) }
    end

    # Copy-on-write with GLSL value semantics; the emitted
    # `obj = rt.assign_swizzle(obj, ...)` rebinds obj to this fresh copy. A
    # stored vector is f32 in JS; snap the base and the assigned value.
    def assign_swizzle(vec, sw, value)
      idx = sw.chars.map { |c| SWIZZLE[c] }
      if _is_ivec(vec)
        v = IVec.new(vec)
        if _is_vec(value)
          val = value.to_a
          idx.each_index { |p| v[idx[p]] = val[p].to_i }
        else
          idx.each { |t| v[t] = value.to_i }
        end
        return v
      end
      v = vec.map { |c| f32(c) }
      if _is_vec(value)
        val = value.map { |c| f32(c) }
        idx.each_index { |p| v[idx[p]] = val[p] }
      else
        # Scalar writes snap too -- the store is into f32 storage.
        sv = f32(value)
        idx.each { |t| v[t] = sv }
      end
      v
    end

    # ---- operators ----

    def binary(op, a, b, width = nil, base = nil)
      base = "float" if base.nil?
      if %w[== != < > <= >= && ||].include?(op)
        return _logical(op, a, b)
      end
      if base == "int" || base == "uint" || %w[& | ^ << >>].include?(op)
        return _int_binary(op, a, b, base == "uint" ? "uint" : "int")
      end
      # Float path: compute raw f64 and DEFER the f32 rounding to the
      # consumption boundaries (see module header).
      fn = case op
           when "+" then ->(x, y) { x + y }
           when "-" then ->(x, y) { x - y }
           when "*" then ->(x, y) { x * y }
           when "/" then ->(x, y) { NoisemakerCpu::UintMath.fdiv(x, y) }
           when "%" then ->(x, y) { y == 0 ? NAN : x.remainder(y) }
           else raise "unsupported binary op '#{op}'"
           end
      _bc2(fn, a, b)
    end

    def unary(op, a, width = nil)
      if op == "-"
        # Defer f32 rounding for vectors (negation is exact); scalars stay f64.
        return -a unless _is_vec(a)

        return a.map { |x| -x }
      end
      return _truthy(a) != 0 ? 0 : 1 if op == "!"
      return a if op == "+"

      raise "unsupported unary op '#{op}'"
    end

    # ---- component-wise builtins ----

    def component_wise(name, *args)
      ov = @stdlib_override[name]
      return ov.call(*args) if ov

      if name == "atan" && args.length == 2 # atan(y, x) -> atan2
        r = _bcn(->(y, x) { Math.atan2(y, x) }, *args)
        return _is_vec(r) ? r.map { |c| f32(c) } : f32(r)
      end
      if (rel = RELATIONAL[name]) # lessThan/equal/... -> bvec
        a, b = args.map { |x| _snap32(x) }
        r = _bcn(rel, a, b)
        return _is_vec(r) ? r : [r]
      end
      return _truthy(args[0]) != 0 ? 1 : 0 if name == "any"
      if name == "all"
        v = args[0]
        return _truthy(v) != 0 ? 1 : 0 unless _is_vec(v)

        v.each { |e| return 0 if e == 0 }
        return 1
      end
      if name == "not"
        v = args[0]
        return _truthy(v) != 0 ? 0 : 1 unless _is_vec(v)

        return v.map { |e| e == 0 ? 1 : 0 }
      end
      # Snap vector args to f32 first (JS applies these to stored
      # Float32Array values), then compute in float64 and round the result
      # to f32.
      fn = COMPONENT[name]
      raise "unsupported builtin '#{name}'" if fn.nil?

      snapped = args.map { |x| _is_vec(x) ? _snap32(x) : x }
      r = _bcn(fn, *snapped)
      _is_vec(r) ? r.map { |c| f32(c) } : f32(r)
    end

    # ---- texture ----

    def texture(sampler, uv)
      # Sample at f32 coords -- JS reads the uv from a stored Float32Array
      # (binary defers the round).
      u = f32(uv[0])
      v = f32(uv[1])
      filt = sampler.filter || "nearest"
      return NoisemakerCpu::Sampler.sample_bilinear(sampler, u, v) if filt == "linear"

      NoisemakerCpu::Sampler.sample_nearest_bottom_left(sampler, u, v)
    end

    def texture_size(sampler)
      [sampler.width.to_f, sampler.height.to_f]
    end

    def texel_fetch(sampler, coord, lod = nil)
      w = sampler.width
      h = sampler.height
      x = _safe_to_i(coord[0])
      x = 0 if x < 0
      x = w - 1 if x > w - 1
      # GL bottom-left origin -> top-down storage row flip (integer texel).
      ty = h - 1 - _safe_to_i(coord[1])
      ty = 0 if ty < 0
      ty = h - 1 if ty > h - 1
      i = ((ty * w) + x) * 4
      d = sampler.data
      d[i, 4]
    end

    # ---- uint32 / half-float primitives (delegate to bit-exact UintMath) ----

    def pcg3d(v)
      r = NoisemakerCpu::UintMath.pcg3d(v.map { |c| c.to_i & U32 })
      IVec.new(r)
    end

    def hash_uint(x)
      NoisemakerCpu::UintMath.hash_uint32(x.to_i & U32)
    end

    def float_bits_to_uint(x)
      NoisemakerCpu::UintMath.float_bits_to_uint(x.to_f)
    end

    def uint_bits_to_float(x)
      f32(NoisemakerCpu::UintMath.uint_bits_to_float(x.to_i & U32))
    end

    def pack_half_2x16(v)
      NoisemakerCpu::UintMath.pack_half_2x16([v[0].to_f, v[1].to_f])
    end

    def unpack_half_2x16(u)
      r = NoisemakerCpu::UintMath.unpack_half_2x16(NoisemakerCpu::UintMath.u32(u))
      r.map { |c| f32(c) }
    end

    def to_int(x)
      # GLSL int(float) truncates toward zero, then wraps. Route through u32
      # so huge floats WRAP mod 2**32 (Ruby Integers never saturate the way
      # Perl's IV does, so this wrap is still required for GLSL parity, just
      # not for the reason Perl needed it).
      return _s32(NoisemakerCpu::UintMath.u32(x)) unless _is_vec(x)

      IVec.new(x.map(&:to_i))
    end

    def to_uint(x)
      return NoisemakerCpu::UintMath.u32(x) unless _is_vec(x)

      IVec.new(x.map { |c| NoisemakerCpu::UintMath.u32(c) })
    end

    # ---- vector geometry (snap args to f32, accumulate float64, round once) ----

    def dot(a, b)
      f32(_dot_raw(_snap32(a), _snap32(b)))
    end

    def length(a)
      # JS length is F32(sqrt(dot)), and its dot is itself F32-rounded -- so
      # the squared magnitude is rounded to f32 before the sqrt.
      v = _snap32(a)
      f32(Math.sqrt(f32(_dot_raw(v, v))))
    end

    def distance(a, b)
      av = _snap32(a)
      bv = _snap32(b)
      d = (0...av.length).map { |idx| av[idx] - bv[idx] }
      f32(Math.sqrt(_dot_raw(d, d)))
    end

    def normalize(a)
      v = _snap32(a)
      # JS normalize divides by length(), which is f32-rounded.
      mag = f32(Math.sqrt(_dot_raw(v, v)))
      return Array.new(v.length, 0.0) if mag == 0.0

      v.map { |c| f32(c / mag) }
    end

    def cross(a, b)
      ax, ay, az = a
      bx, by, bz = b
      [
        f32((ay * bz) - (az * by)),
        f32((az * bx) - (ax * bz)),
        f32((ax * by) - (ay * bx)),
      ]
    end

    def reflect(i, n)
      d = _dot_raw(n, i)
      (0...i.length).map { |idx| f32(i[idx] - (2.0 * d * n[idx])) }
    end

    def refract(i, n, eta)
      e = eta.to_f
      d = _dot_raw(n, i)
      k = 1.0 - (e * e * (1.0 - (d * d)))
      return Array.new(i.length, 0.0) if k < 0.0

      c = (e * d) + Math.sqrt(k)
      (0...i.length).map { |idx| f32((e * i[idx]) - (c * n[idx])) }
    end

    # ---- matrices (flat, column-major: element [col*N + row]) ----

    def matrix_mult(a, b, dim)
      n = dim.to_i
      a_mat = a.length == n * n
      b_mat = b.length == n * n
      r = []
      if a_mat && b_mat # GLSL A*B, both column-major
        (0...n).each do |mi|
          (0...n).each do |mj|
            s = 0
            (0...n).each { |k| s += b[(mi * n) + k] * a[(k * n) + mj] }
            r[(mi * n) + mj] = f32(s)
          end
        end
      elsif a_mat # mat * vec
        (0...n).each do |mj|
          s = 0
          (0...n).each { |k| s += b[k] * a[(k * n) + mj] }
          r[mj] = f32(s)
        end
      else # vec * mat
        (0...n).each do |mi|
          s = 0
          (0...n).each { |k| s += b[(mi * n) + k] * a[k] }
          r[mi] = f32(s)
        end
      end
      r
    end

    def mat_col(mat, i, dim)
      n = dim.to_i
      c = i.to_i
      mat[(c * n)...((c + 1) * n)].map { |x| f32(x) }
    end

    # ---- arrays (GLSL fixed-size arrays -> Ruby Arrays) ----

    def new_array(n, width = nil)
      n = n.to_i
      width = 1 if width.nil?
      return Array.new(n, 0.0) if width <= 1

      Array.new(n) { Array.new(width, 0.0) }
    end

    def array(elems)
      elems.dup
    end

    def bit_not(x)
      return _s32(-x.to_i - 1) unless _is_vec(x)

      IVec.new(x.map { |c| -c.to_i - 1 })
    end

    private

    # NB: this class defines methods named `length`, `f`, and `i`
    # (kernel-facing methods, matching Perl's Runtime.pm which warns about
    # the same names colliding with builtins). Object/Kernel do not define
    # any of these by default, so no special handling is needed in Ruby.

    def _is_vec(v)
      v.is_a?(Array)
    end

    def _is_ivec(v)
      v.is_a?(IVec)
    end

    # Snap a float vector to f32 at a storage/consumption boundary. Int
    # vectors pass through unchanged.
    def _snap32(v)
      return v unless _is_vec(v)
      return v if _is_ivec(v)

      v.map { |c| f32(c) }
    end

    def _s32(x)
      ((x.to_i + 0x80000000) & U32) - 0x80000000
    end

    def _zero_like(v)
      return 0.0 unless _is_vec(v)

      Array.new(v.length, 0.0)
    end

    def _deriv(op, v)
      mode = @deriv_mode || ""
      if mode == "record"
        # Recorded values snap to f32 -- the reference records into a
        # Float32Array; recording raw deferred f64 would double-round
        # differently in deriv_fine.
        @deriv_log << [op, _is_vec(v) ? v.map { |c| f32(c) } : v]
        @deriv_i += 1
        return _zero_like(v)
      end
      if mode == "replay"
        d = if @deriv_i < @deriv_diffs.length
              @deriv_diffs[@deriv_i][op]
            else
              _zero_like(v)
            end
        @deriv_i += 1
        return d
      end
      _zero_like(v)
    end

    def _bc2(fn, a, b)
      if _is_vec(a)
        return (0...a.length).map { |idx| fn.call(a[idx], b[idx]) } if _is_vec(b)

        return a.map { |x| fn.call(x, b) }
      end
      return b.map { |x| fn.call(a, x) } if _is_vec(b)

      fn.call(a, b)
    end

    # N-ary broadcast: applies fn component-wise if any arg is a vector
    # (width taken from the first vector arg encountered), else calls fn
    # once on the plain scalars.
    def _bcn(fn, *args)
      w = nil
      args.each { |a| w = a.length if _is_vec(a) && w.nil? }
      return fn.call(*args) if w.nil?

      (0...w).map { |idx| fn.call(*args.map { |a| _is_vec(a) ? a[idx] : a }) }
    end

    def _int_binary(op, a, b, base)
      return _int_scalar(op, a.to_i, b.to_i, base) unless _is_vec(a) || _is_vec(b)

      r = _bc2(->(x, y) { _int_scalar(op, x.to_i, y.to_i, base) }, a, b)
      IVec.new(r)
    end

    def _int_scalar(op, a, b, base)
      if base == "uint"
        a &= U32
        b &= U32
        case op
        when "+" then return NoisemakerCpu::UintMath.uadd(a, b)
        when "-" then return NoisemakerCpu::UintMath.usub(a, b)
        when "*" then return NoisemakerCpu::UintMath.umul(a, b)
        when "&" then return NoisemakerCpu::UintMath.uand(a, b)
        when "|" then return NoisemakerCpu::UintMath.uor(a, b)
        when "^" then return NoisemakerCpu::UintMath.uxor(a, b)
        when "<<" then return NoisemakerCpu::UintMath.ushl(a, b)
        when ">>" then return NoisemakerCpu::UintMath.ushr(a, b)
        when "/" then return b != 0 ? a / b : 0 # a,b non-negative (masked above): truncating == Ruby's Integer#/
        when "%" then return b != 0 ? a % b : 0 # ditto: no sign ambiguity when both operands are non-negative
        else raise "unsupported uint op '#{op}'"
        end
      end
      return _s32(a + b) if op == "+"
      return _s32(a - b) if op == "-"
      return _s32(a * b) if op == "*"
      return _s32(a & b) if op == "&"
      return _s32(a | b) if op == "|"
      return _s32(a ^ b) if op == "^"
      return _s32(a << (b & 31)) if op == "<<"
      if op == ">>"
        # Ruby's native `>>` on a negative Integer is already an ARITHMETIC
        # shift (arbitrary-precision two's complement sign-extends), unlike
        # Perl's raw `>>` on a negative IV (a 64-bit LOGICAL shift -- see
        # Perl Runtime.pm's own comment on this op, which then restores the
        # sign via _s32 as a fix-up). No logical-shift-then-resign
        # workaround is needed in Ruby; verified against both regression
        # goldens (-8 >> 2 == -2, -1 >> 31 == -1).
        return _s32(a >> (b & 31))
      end
      return b != 0 ? _s32(a.fdiv(b).truncate) : 0 if op == "/"
      return b != 0 ? _s32(a - (b * a.fdiv(b).truncate)) : 0 if op == "%"

      raise "unsupported int op '#{op}'"
    end

    def _truthy(v)
      return v.count { |x| x != 0 } if _is_vec(v)

      v != 0 ? 1 : 0
    end

    def _logical(op, a, b)
      if op == "==" || op == "!="
        if _is_vec(a) || _is_vec(b)
          all_eq = true
          n = _is_vec(a) ? a.length : b.length
          (0...n).each do |idx|
            x = _is_vec(a) ? a[idx] : a
            y = _is_vec(b) ? b[idx] : b
            if x != y
              all_eq = false
              break
            end
          end
          return op == "==" ? (all_eq ? 1 : 0) : (all_eq ? 0 : 1)
        end
        return op == "==" ? (a == b ? 1 : 0) : (a != b ? 1 : 0)
      end
      # Ordering comparisons are scalar-only (the codegen routes vector
      # comparisons to lessThan/greaterThan/...). Comparing Arrays here
      # would silently compare identity/contents oddly -- fail loudly
      # instead.
      raise "scalar relational '#{op}' applied to a vector" if _is_vec(a) || _is_vec(b)
      return a < b ? 1 : 0 if op == "<"
      return a > b ? 1 : 0 if op == ">"
      return a <= b ? 1 : 0 if op == "<="
      return a >= b ? 1 : 0 if op == ">="
      return (_truthy(a) != 0 && _truthy(b) != 0) ? 1 : 0 if op == "&&"
      return (_truthy(a) != 0 || _truthy(b) != 0) ? 1 : 0 if op == "||"

      raise "unsupported logical op '#{op}'"
    end

    def _dot_raw(a, b)
      s = 0
      (0...a.length).each { |idx| s += a[idx] * b[idx] }
      s
    end

    # Perl's bareword `int($coord->[N])` never raises; Ruby's Float#to_i
    # raises FloatDomainError on NaN/Infinity. u/v reaching texel_fetch are
    # expected finite (integer texel coordinates), but this guards the same
    # way sampler.rb does rather than crashing the render on a pathological
    # upstream divide-by-zero.
    def _safe_to_i(x)
      return 0 if x.is_a?(Float) && !x.finite?

      x.to_i
    end
  end
end
