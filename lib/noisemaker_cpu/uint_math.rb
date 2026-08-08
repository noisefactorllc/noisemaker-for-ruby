# frozen_string_literal: true

# GPU-accurate uint32 and half-float integer primitives.
#
# Faithful, bit-exact port of the integer/bitwise helpers in noisemaker-cpu
# src/csl/glsl-runtime.js (uint32, pcg3d, hashUint32, floatBitsToUint,
# packHalf2x16/unpackHalf2x16, glslMod) plus the uint32 arithmetic that backs
# GLSL `uint` operators in transpiled kernels. Self-contained: Ruby stdlib
# only (no requires).
#
# Ruby notes vs the Perl source (lib/Math/Fractal/Noisemaker/UintMath.pm):
# - Ruby Integers are arbitrary-precision, so unlike Perl (whose signed
#   64-bit IVs silently degrade to an imprecise NV above 2**63), plain `&`
#   masking is always exact here -- no 16-bit-split multiply workaround is
#   needed for `umul`. It is still masked with & MASK32 after every op,
#   exactly mirroring what UintMath.pm does (JS `Math.imul(a, b) >>> 0`).
# - float32 bit reinterpretation uses `pack('e')`/`unpack('V')` (explicit
#   little-endian), not Perl's native-order `pack('f')`/`pack('L')` --
#   contract trap #4 mandates the explicit-LE pairing so the port is
#   deterministic across host byte orders. Verified bit-for-bit identical to
#   Perl's native-order pack on this (little-endian) host for every golden
#   vector in t/01-uintmath.t.
# - Perl constants `_INF`/`_NAN` are built via `9**9**9` (NV overflow to
#   Infinity). Ruby Integers are arbitrary-precision, so `9**9**9` is a
#   ~369-million-digit Bignum, NOT Infinity -- using it would be wrong *and*
#   pathologically slow. `Float::INFINITY`/`Float::NAN` are the same IEEE-754
#   values Perl's idiom produces; used directly instead.
# - Ruby's native `Float#floor`/`#ceil`/`#truncate` raise FloatDomainError on
#   NaN/Infinity input (Perl's POSIX::floor/ceil/trunc, like JS Math.floor
#   etc., silently propagate NaN/Inf). `glsl_mod`'s quotient can be
#   +-Infinity (y == 0, x != 0), so its floor() call is routed through the
#   local `_safe_floor` guard below to avoid a crash where Perl/JS would not
#   raise. See docs/2026-08-08-ruby-port-contract.md worker-A report for the
#   full flag -- this is NOT one of the contract's enumerated traps.

module NoisemakerCpu
  module UintMath
    MASK32 = 0xFFFFFFFF

    INF = Float::INFINITY
    NAN = Float::NAN

    # IEEE division: n/0 -> +-Inf, 0/0 -> NaN (Ruby Integer#/ raises
    # ZeroDivisionError on zero divide; Float#/ does not, but we route
    # through here uniformly so Integer and Float numerators/denominators
    # both get IEEE semantics, matching Perl's fdiv wrapping Perl's own
    # die-on-integer-zero-divide `/`).
    # Honors the sign of a negative-zero denominator (n / -0.0 == -Inf).
    def self.fdiv(n, d)
      if d == 0
        return NAN if n == 0 || (n.is_a?(Float) && n.nan?)
        neg_zero = ((([d.to_f].pack('d').unpack1('Q')) >> 63) & 1) == 1
        inf = (n > 0) == !neg_zero ? INF : -INF
        return inf
      end
      n.fdiv(d)
    end

    # Perl POSIX::floor / JS Math.floor propagate NaN/Infinity unchanged;
    # Ruby's native Float#floor raises FloatDomainError on non-finite input.
    # Only used internally by glsl_mod, whose quotient can be non-finite.
    def self._safe_floor(x)
      return x if x.is_a?(Float) && !x.finite?
      return x if x == 0 # preserve -0.0 sign (Integer#floor.to_f loses it)
      x.floor.to_f
    end

    # Coerce a scalar to a plain integer for bitwise work. Floats truncate
    # toward zero (JS ToInt32/ToUint32); NaN/Infinity coerce to 0 (JS
    # `NaN >>> 0 === 0`).
    #
    # Perl's version reduces mod 2**32 via fmod BEFORE converting to IV,
    # because Perl's NV->IV conversion corrupts low bits above 2**53 (a
    # fixed 64-bit IV can't hold an exact NV mantissa past that). Ruby
    # Integers are arbitrary-precision, so Float#truncate is exact at any
    # magnitude -- the corruption Perl works around cannot happen here. This
    # is still ported as its own explicit path (not simplified to `x & 0xFF..`)
    # for structural parity and because the NaN/Infinity guards are required
    # regardless (see module header on FloatDomainError).
    def self._int_operand(x)
      return 0 if x.is_a?(Float) && x.nan? # NaN
      return 0 if x.is_a?(Float) && x.infinite? # +-Inf
      x.truncate
    end

    # JS `value >>> 0` -- unsigned 32-bit with wraparound.
    def self.u32(x)
      _int_operand(x) & MASK32
    end

    # JS `Math.imul(a, b) >>> 0` -- 32-bit wrapping multiply, unsigned result.
    def self.umul(a, b)
      (u32(a) * u32(b)) & MASK32
    end

    def self.uadd(a, b)
      (u32(a) + u32(b)) & MASK32
    end

    def self.usub(a, b)
      (u32(a) - u32(b)) & MASK32
    end

    def self.ushl(a, b)
      (u32(a) << (u32(b) & 0x1F)) & MASK32
    end

    def self.ushr(a, b)
      (u32(a) >> (u32(b) & 0x1F)) & MASK32
    end

    def self.uand(a, b)
      u32(a) & u32(b)
    end

    def self.uor(a, b)
      u32(a) | u32(b)
    end

    def self.uxor(a, b)
      u32(a) ^ u32(b)
    end

    # Floored modulo -- GLSL/JS `x - y * floor(x / y)` (NOT Ruby's %).
    # Non-finite quotients (y == 0) propagate Inf/NaN like JS instead of
    # raising.
    def self.glsl_mod(x, y)
      q = fdiv(x, y)
      return NAN if q.is_a?(Float) && q.nan?

      x - y * _safe_floor(q)
    end

    # 3-lane PCG hash (uvec3 -> uvec3). Sequential in-place lane updates:
    # later lanes read the already-updated earlier lanes, exactly matching
    # the JS statement order. A "parallel" translation gives the wrong
    # answer.
    def self.pcg3d(v3)
      x = u32(v3[0])
      y = u32(v3[1])
      z = u32(v3[2])

      x = uadd(umul(x, 1664525), 1013904223)
      y = uadd(umul(y, 1664525), 1013904223)
      z = uadd(umul(z, 1664525), 1013904223)

      x = uadd(x, umul(y, z))
      y = uadd(y, umul(z, x))
      z = uadd(z, umul(x, y))

      x = uxor(x, ushr(x, 16))
      y = uxor(y, ushr(y, 16))
      z = uxor(z, ushr(z, 16))

      x = uadd(x, umul(y, z))
      y = uadd(y, umul(z, x))
      z = uadd(z, umul(x, y))

      [x, y, z]
    end

    # Murmur-style uint32 finalizer (hashUint32 in glsl-runtime.js).
    def self.hash_uint32(x)
      r = u32(x)
      r = uxor(r, ushr(r, 16))
      r = umul(r, 0x7FEB352D)
      r = uxor(r, ushr(r, 15))
      r = umul(r, 0x846CA68B)
      r = uxor(r, ushr(r, 16))
      r
    end

    # stdlib.hashUint is a bare alias for hashUint32 in glsl-runtime.js.
    class << self
      alias_method :hash_uint, :hash_uint32
    end

    # Reinterpret a float32's bits as a uint32 (GLSL floatBitsToUint). The
    # value is first rounded to float32 by pack('e'), matching JS
    # Float32Array[0] = f. Explicit little-endian pack/unpack pairing (see
    # module header); the pairing is self-consistent so the reinterpreted
    # bits are correct regardless of host byte order.
    def self.float_bits_to_uint(x)
      [x].pack('e').unpack1('V')
    end

    # Inverse reinterpretation (GLSL uintBitsToFloat).
    def self.uint_bits_to_float(x)
      [u32(x)].pack('V').unpack1('e')
    end

    # Decode one IEEE-754 binary16 to a float (halfToFloat in
    # glsl-runtime.js).
    def self._half_to_float(bits)
      bits &= 0xFFFF
      sign = (bits & 0x8000) != 0 ? -1 : 1
      exponent = (bits >> 10) & 0x1F
      fraction = bits & 0x3FF
      if exponent == 0
        return sign * (2**-14) * (fraction / 1024.0)
      end
      if exponent == 0x1F
        return fraction != 0 ? NAN : sign * INF
      end
      sign * (2**(exponent - 15)) * (1 + fraction / 1024.0)
    end

    # Encode a float to one binary16 (round-to-nearest, denormals,
    # saturating overflow) -- floatToHalf in glsl-runtime.js.
    def self._float_to_half(value)
      return 0x7E00 if value.is_a?(Float) && value.nan?
      return 0x7C00 if value == INF
      return 0xFC00 if value == -INF

      bits = [value].pack('e').unpack1('V')
      sign = (bits >> 16) & 0x8000
      exponent = ((bits >> 23) & 0xFF) - 127 + 15
      fraction = bits & 0x7FFFFF
      if exponent <= 0
        return sign if exponent < -10
        fraction = (fraction | 0x800000) >> (1 - exponent)
        return sign | ((fraction + 0x1000) >> 13)
      end
      return sign | 0x7C00 if exponent >= 31

      fraction += 0x1000
      if (fraction & 0x800000) != 0
        fraction = 0
        exponent += 1
        return sign | 0x7C00 if exponent >= 31
      end
      sign | (exponent << 10) | (fraction >> 13)
    end

    # GLSL packHalf2x16: v[0] low 16 bits, v[1] high 16.
    def self.pack_half_2x16(v2)
      lo = _float_to_half(v2[0])
      hi = _float_to_half(v2[1])
      (lo | (hi << 16)) & MASK32
    end

    # GLSL unpackHalf2x16 -- inverse of pack_half_2x16.
    def self.unpack_half_2x16(u)
      uu = u32(u)
      [_half_to_float(uu & 0xFFFF), _half_to_float((uu >> 16) & 0xFFFF)]
    end
  end
end
