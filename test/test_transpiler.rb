# frozen_string_literal: true

# Full Ruby-transpiler pipeline: inline GLSL -> Preprocess.normalize ->
# Parser.parse -> Codegen.emit_ruby -> assert on the emitted Ruby text, plus
# an end-to-end eval-and-render check against a stub rt/ctx (mirrors
# noisemaker-for-python's tests/test_transpiler.py pipeline shape: CDN ->
# normalize -> parse -> emit -> load_kernel -> run; substitutes inline GLSL
# snippets for the CDN fetch, since this worker may not touch the network,
# and a minimal in-file stub runtime for noisemaker_cpu.runtime, since that
# is Worker A's module and may not exist yet during parallel development).
#
# Everything below lives inside TestTranspilerPipeline (helpers, stub
# rt/ctx classes, module aliases) rather than at the top level: `rake test`
# loads every worker's test/test_*.rb into one process, and top-level defs
#/ constants here would leak into Object and risk colliding with another
# worker's test file.

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/transpiler/shared_enums"
require_relative "../lib/noisemaker_cpu/transpiler/computed_defs"
require_relative "../lib/noisemaker_cpu/transpiler/lexer"
require_relative "../lib/noisemaker_cpu/transpiler/preprocess"
require_relative "../lib/noisemaker_cpu/transpiler/parser"
require_relative "../lib/noisemaker_cpu/transpiler/codegen"

class TestTranspilerPipeline < Minitest::Test
  Preprocess = NoisemakerCpu::Transpiler::Preprocess
  Lexer = NoisemakerCpu::Transpiler::Lexer
  Parser = NoisemakerCpu::Transpiler::Parser
  Codegen = NoisemakerCpu::Transpiler::Codegen

  # -------------------------------------------------------------------------
  # Minimal stub rt/ctx for the end-to-end eval check. This is a test double
  # only -- not a preview of Worker A's real noisemaker_cpu/runtime.rb --
  # just enough GLSL-primitive semantics to run the tiny inline shaders
  # exercised below (plain float32 arithmetic, no uint-wraparound
  # bit-exactness).
  class StubRuntime
    SWZ = { "x" => 0, "y" => 1, "z" => 2, "w" => 3, "r" => 0, "g" => 1, "b" => 2, "a" => 3 }.freeze

    def f(x) = x.to_f
    def i(x) = x.to_i

    def f32(x)
      [x].pack("e").unpack1("e")
    end

    def bool(x) = x != 0

    def copy(vec, _base = nil)
      vec.is_a?(Array) ? vec.dup : vec
    end

    def construct(width, *rest)
      base = rest.last.is_a?(String) ? rest.pop : nil
      flat = rest.flat_map { |r| r.is_a?(Array) ? r : [r] }
      vals = (flat.length == 1 && width > 1) ? Array.new(width, flat[0]) : flat.first(width)
      vals = vals.map { |v| (base == "int" || base == "uint") ? v.to_i : v.to_f }
      width == 1 ? vals[0] : vals
    end

    def array(elems) = elems

    def new_array(n, width)
      Array.new(n) { width == 1 ? 0.0 : Array.new(width, 0.0) }
    end

    def swizzle(vec, sw)
      idxs = sw.chars.map { |c| SWZ.fetch(c) }
      vals = idxs.map { |i| vec[i] }
      vals.length == 1 ? vals[0] : vals
    end

    def assign_swizzle(vec, sw, value)
      idxs = sw.chars.map { |c| SWZ.fetch(c) }
      out = vec.dup
      vv = idxs.length == 1 ? [value] : value
      idxs.each_index { |k| out[idxs[k]] = vv[k] }
      out
    end

    def unary(op, x)
      case op
      when "+" then x
      when "-" then x.is_a?(Array) ? x.map { |v| -v } : -x
      end
    end

    def bit_not(x) = ~x

    def binary(op, a, b, width = nil, base = nil)
      scalar = lambda do |x, y|
        case op
        when "==" then x == y ? 1 : 0
        when "!=" then x != y ? 1 : 0
        when "<" then x < y ? 1 : 0
        when ">" then x > y ? 1 : 0
        when "<=" then x <= y ? 1 : 0
        when ">=" then x >= y ? 1 : 0
        when "+" then x + y
        when "-" then x - y
        when "*" then x * y
        when "/" then (base == "int" || base == "uint") ? (x.to_i / y.to_i) : x.fdiv(y)
        when "%" then x % y
        when "&" then x.to_i & y.to_i
        when "|" then x.to_i | y.to_i
        when "^" then x.to_i ^ y.to_i
        when "<<" then x.to_i << y.to_i
        when ">>" then x.to_i >> y.to_i
        else raise "StubRuntime#binary: unhandled op #{op}"
        end
      end
      return scalar.call(a, b) if %w[== != < > <= >=].include?(op)

      if a.is_a?(Array) || b.is_a?(Array)
        n = width || (a.is_a?(Array) ? a.length : b.length)
        av = a.is_a?(Array) ? a : Array.new(n, a)
        bv = b.is_a?(Array) ? b : Array.new(n, b)
        (0...n).map { |k| scalar.call(av[k], bv[k]) }
      else
        scalar.call(a, b)
      end
    end

    def component_wise(name, *args)
      if name == "all"
        v = args[0]
        return (v.is_a?(Array) ? v.all? { |x| x != 0 } : v != 0) ? 1 : 0
      end
      fn = lambda do |*xs|
        case name
        when "min" then xs[0] < xs[1] ? xs[0] : xs[1]
        when "max" then xs[0] > xs[1] ? xs[0] : xs[1]
        when "abs" then xs[0].abs
        when "clamp" then [[xs[0], xs[1]].max, xs[2]].min
        when "mix" then xs[0] + ((xs[1] - xs[0]) * xs[2])
        when "floor" then xs[0].floor.to_f
        when "fract" then xs[0] - xs[0].floor
        when "mod" then xs[0] - (xs[1] * (xs[0] / xs[1]).floor)
        when "sin" then Math.sin(xs[0])
        when "cos" then Math.cos(xs[0])
        when "sqrt" then Math.sqrt(xs[0])
        when "pow" then xs[0]**xs[1]
        when "radians" then xs[0] * Math::PI / 180.0
        when "equal" then xs[0] == xs[1] ? 1 : 0
        else raise "StubRuntime#component_wise: unhandled builtin #{name}"
        end
      end
      widths = args.map { |a| a.is_a?(Array) ? a.length : 1 }
      w = widths.max
      if w > 1
        vecs = args.map { |a| a.is_a?(Array) ? a : Array.new(w, a) }
        (0...w).map { |k| fn.call(*vecs.map { |v| v[k] }) }
      else
        fn.call(*args)
      end
    end

    def dot(a, b) = a.zip(b).sum { |x, y| x * y }
    def length(v) = Math.sqrt(v.is_a?(Array) ? v.sum { |x| x * x } : v * v)

    def normalize(v)
      l = length(v)
      v.map { |x| x / l }
    end

    def texture(tex, _uv) = tex.dup
    def texture_size(_tex) = [1, 1]
    def texel_fetch(tex, _coord, _lod) = tex.dup

    def matrix_mult(m, v, n)
      if v.length == n
        (0...n).map { |row| (0...n).sum { |col| m[(col * n) + row] * v[col] } }
      else
        out = Array.new(n * n, 0.0)
        (0...n).each do |col|
          (0...n).each do |row|
            out[(col * n) + row] = (0...n).sum { |k| m[(k * n) + row] * v[(col * n) + k] }
          end
        end
        out
      end
    end

    def mat_col(m, idx, n) = m[(idx * n)...((idx * n) + n)]
  end

  class StubCtx
    attr_reader :rt, :uniforms, :frag_coord, :uv

    def initialize(rt, uniforms:, textures: {}, frag_coord: [0.0, 0.0, 0.0, 1.0], uv: [0.0, 0.0])
      @rt = rt
      @uniforms = uniforms
      @textures = textures
      @frag_coord = frag_coord
      @uv = uv
    end

    def texture_binding(name)
      @textures.fetch(name)
    end
  end

  # ---- SharedEnums / ComputedDefs sanity ----

  def test_shared_enums_palette_table
    palette = NoisemakerCpu::Transpiler::SharedEnums::SHARED_ENUMS["palette"]
    assert_equal 56, palette.size
    assert_equal 0, palette["none"]
    assert_equal 7, palette["brushedMetal"]
    assert_equal 55, palette["vintagePhoto"]
  end

  def test_computed_defs_mashup_and_remap
    defs = NoisemakerCpu::Transpiler::ComputedDefs::COMPUTED_DEFS
    mashup = defs["mixer/mashup"]
    assert_equal "mixer", mashup["namespace"]
    assert_equal "mashup", mashup["func"]
    assert_includes mashup["params"], "layer7_tex"
    refute_includes mashup["params"], "layer8_tex"
    assert_equal "layer0_active", mashup["params"]["layer0_tex"]["colorModeUniform"]
    assert_equal %w[source layers smoothness] + (0..7).map { |e| "layer#{e}_tex" }, mashup["paramOrder"]

    remap = defs["synth/remap"]
    assert_equal "synth", remap["namespace"]
    assert_includes remap["params"], "zone7_tex"
    assert_equal(%w[zoneCount bgColor bgAlpha smoothEdge] + (0..7).map { |z| "zone#{z}_tex" }, remap["paramOrder"])
  end

  # ---- Lexer ----

  def test_lexer_tokenizes_numbers_idents_ops_and_strips_comments
    toks = Lexer.tokenize("float x = 1.5e-3 + 0x1Fu; // trailing\n/* block */ vec2 uv;")
    kinds = toks.map { |t| [t["kind"], t["value"]] }
    assert_equal [
      ["id", "float"], ["id", "x"], ["op", "="], ["num", "1.5e-3"], ["op", "+"], ["num", "0x1Fu"],
      ["op", ";"], ["id", "vec2"], ["id", "uv"], ["op", ";"], ["op", "<eof>"],
    ], kinds
  end

  # ---- Preprocess ----

  def test_preprocess_expands_defines_and_strips_directives
    norm = Preprocess.normalize(<<~GLSL, {})
      #version 300 es
      #define N 4
      out vec4 fragColor;
      in vec2 vTexCoord;
      void main() { int n = N; fragColor = vec4(0.0); }
    GLSL
    refute_includes norm["source"], "#version"
    assert_includes norm["source"], "int n = 4;"
    assert_equal ["fragColor"], norm["outputs"]
    assert_equal ["vTexCoord"], norm["varyings"]
  end

  def test_preprocess_records_mrt_outputs_in_location_order
    norm = Preprocess.normalize(<<~GLSL, {})
      #version 300 es
      layout(location = 1) out vec4 outVel;
      layout(location = 0) out vec4 outXYZ;
      void main() {
        outXYZ = vec4(1.0, 0.0, 0.0, 1.0);
        outVel = vec4(0.0, 1.0, 0.0, 1.0);
      }
    GLSL
    assert_equal [
      { "name" => "outXYZ", "location" => 0 },
      { "name" => "outVel", "location" => 1 },
    ], norm["outputLocations"]
    assert_equal %w[outXYZ outVel], norm["outputs"]
  end

  def test_mrt_codegen_writes_every_output_chunk
    source = <<~GLSL
      layout(location = 1) out vec4 outVel;
      layout(location = 0) out vec4 outXYZ;
      void main() {
        outXYZ = vec4(1.0, 2.0, 3.0, 4.0);
        outVel = vec4(5.0, 6.0, 7.0, 8.0);
      }
    GLSL
    result = eval(transpile(source), TOPLEVEL_BINDING.dup, "test_mrt_kernel") # rubocop:disable Security/Eval
    assert_equal %w[outXYZ outVel], result[:output_names]
    out = Array.new(8, 0.0)
    result[:kernel].call(StubCtx.new(StubRuntime.new, uniforms: {}), out)
    assert_equal (1..8).map(&:to_f), out
  end

  def test_preprocess_static_ifdef_takes_the_defined_branch
    norm = Preprocess.normalize(<<~GLSL, {})
      #ifdef FOO
      float y = 1.0;
      #else
      float y = 2.0;
      #endif
    GLSL
    assert_includes norm["source"], "float y = 2.0;"
    refute_includes norm["source"], "1.0"
  end

  def test_preprocess_runtime_define_lowers_to_uniform_and_includes_all_branches
    norm = Preprocess.normalize(<<~GLSL, { "RFLAG" => "int" })
      #if RFLAG
      float y = 1.0;
      #else
      float y = 2.0;
      #endif
    GLSL
    assert_includes norm["source"], "uniform int RFLAG;"
    assert_includes norm["source"], "1.0"
    assert_includes norm["source"], "2.0"
  end

  # #if arithmetic exercises the hand-rolled evaluator (see preprocess.rb):
  # Ruby's own eval() can't be reused because 0 is truthy in Ruby, so
  # `0 || (300 >= 100)` would short-circuit to 0 in a naive Ruby eval where
  # Perl's eval (0 is falsy) returns the right operand.
  def test_preprocess_if_expression_evaluator_matches_perl_truthiness
    assert_equal 1, Preprocess._eval_cond("if 0 || (300 >= 100)", "if", {}, {})
    assert_equal 0, Preprocess._eval_cond("if 1 && 0", "if", {}, {})
    assert_equal 1, Preprocess._eval_cond("if (2+3) == 5", "if", {}, {})
    assert_equal 1, Preprocess._eval_cond("if !0", "if", {}, {})
    assert_equal 0, Preprocess._eval_cond("if !1", "if", {}, {})
  end

  # ---- Parser ----

  def test_parser_builds_expected_ast_shape
    ast = Parser.parse("void main() { float x = 1.0 + 2.0; }")
    assert_equal "program", ast["k"]
    fn = ast["decls"][0]
    assert_equal "func", fn["k"]
    assert_equal "main", fn["name"]
    decl = fn["body"][0]
    assert_equal "decl", decl["k"]
    init = decl["declarators"][0]["init"]
    assert_equal "binary", init["k"]
    assert_equal "+", init["op"]
  end

  # ---- Codegen: structural assertions on emitted Ruby ----

  INVERT_GLSL = <<~GLSL
    uniform sampler2D inputTex;
    uniform int mode;
    out vec4 fragColor;
    void main() {
      ivec2 texSize = textureSize(inputTex);
      vec2 uv = gl_FragCoord.xy / vec2(texSize);
      vec4 color = texture(inputTex, uv);
      if (mode == 1) {
        color.rgb = min(color.rgb, 1.0 - color.rgb);
      } else {
        color.rgb = 1.0 - color.rgb;
      }
      fragColor = color;
    }
  GLSL

  def test_emits_normative_kernel_shape
    src = transpile(INVERT_GLSL)
    assert_match(/\A# Generated by NoisemakerCpu::Transpiler - do not edit\.\nrun_pixel = lambda do \|ctx, out\|\n/, src)
    assert_includes src, "rt = ctx.rt"
    assert_includes src, "u = ctx.uniforms"
    assert_includes src, "g = {}"
    assert_includes src, "main__void = nil"
    assert_includes src, "_u_inputTex = ctx.texture_binding('inputTex')"
    assert_includes src, "_u_mode = u.key?('mode') ? u['mode'] : 0"
    assert_includes src, "g['fragColor'] = rt.construct(4, 0.0)"
    assert_includes src, "main__void.call"
    assert_match(/\{ kernel: run_pixel, uses_derivatives: (true|false) \}\n\z/, src)
    assert_includes src, "out[0] = rt.f32(c[0]); out[1] = rt.f32(c[1]); out[2] = rt.f32(c[2]); out[3] = rt.f32(c[3])"
  end

  def test_condition_bearing_shader_wraps_every_condition_in_rt_bool
    src = transpile(INVERT_GLSL)
    assert_includes src, "rt.bool("
    # No bare numeric/identifier condition contexts: every `if`/`unless` line
    # this codegen emits must route through rt.bool(...), never a raw
    # comparison or plain variable (Ruby trap #1 -- 0 is truthy in Ruby).
    src.each_line do |line|
      next unless line =~ /^\s*(if|unless)\s+(.*)$/

      cond = Regexp.last_match(2).strip
      assert_match(/\Art\.bool\(/, cond, "condition line not wrapped in rt.bool: #{line.inspect}")
    end
  end

  def test_in_place_vector_store_uses_replace_for_aliasing
    src = transpile(INVERT_GLSL)
    # fragColor = color; is a width>1 plain-id reassignment -> in-place
    # Array#replace (see codegen.rb header comment / port report for why
    # this differs from the port contract's plain-rebind illustration).
    assert_includes src, "g['fragColor'].replace("
    # Swizzle-target assignment (color.rgb = ...) stays a plain rebind.
    assert_includes src, "color = rt.assign_swizzle(color, 'rgb',"
  end

  def test_hex_and_uint_literal_round_trip
    src = transpile(<<~GLSL)
      out vec4 fragColor;
      void main() {
        uint m = 0xFFu;
        int h = 0x1234abcd;
        fragColor = vec4(float(m), float(h), 0.0, 1.0);
      }
    GLSL
    assert_includes src, "rt.i(255)" # 0xFFu
    assert_includes src, "rt.i(305441741)" # 0x1234abcd
  end

  def test_float_literal_formatting_matches_perl_g17
    src = transpile(<<~GLSL)
      out vec4 fragColor;
      void main() { fragColor = vec4(6.28318530718, 0.15, 0.0, 1.0); }
    GLSL
    assert_includes src, "rt.f(6.2831853071800001)"
    assert_includes src, "rt.f(0.14999999999999999)"
  end

  FOR_LOOP_GLSL = <<~GLSL
    out vec4 fragColor;
    void main() {
      float total = 0.0;
      for (int i = 0; i < 5; i++) {
        total += float(i);
      }
      fragColor = vec4(total, 0.0, 0.0, 1.0);
    }
  GLSL

  def test_for_loop_uses_hard_capped_break_idiom
    src = transpile(FOR_LOOP_GLSL)
    assert_includes src, "(0..1048575).each do |_for0|"
    assert_includes src, "_for0_first"
    assert_includes src, "rt.bool("
    assert_includes src, "break"
  end

  OVERLOAD_GLSL = <<~GLSL
    float pick(float a, float b) { return a + b; }
    int pick(int a, int b) { return a - b; }
    out vec4 fragColor;
    void main() {
      float f = pick(1.0, 2.0);
      int n = pick(3, 4);
      fragColor = vec4(f, float(n), 0.0, 1.0);
    }
  GLSL

  def test_overloaded_functions_get_distinct_mangled_names
    src = transpile(OVERLOAD_GLSL)
    assert_includes src, "pick__float_float = lambda do"
    assert_includes src, "pick__int_int = lambda do"
    assert_includes src, "pick__float_float.call(rt.f(1), rt.f(2))"
    assert_includes src, "pick__int_int.call(rt.i(3), rt.i(4))"
  end

  MATRIX_GLSL = <<~GLSL
    out vec4 fragColor;
    vec2 rotate(vec2 v, float a) {
      mat2 m = mat2(cos(a), sin(a), -sin(a), cos(a));
      return m * v;
    }
    void main() {
      vec2 r = rotate(vec2(1.0, 0.0), 1.5707963267948966);
      fragColor = vec4(r, 0.0, 1.0);
    }
  GLSL

  def test_matrix_construct_and_multiply
    src = transpile(MATRIX_GLSL)
    assert_includes src, "rt.construct(4, rt.component_wise('cos'"
    assert_includes src, "rt.matrix_mult(m, v, 2)"
  end

  STRUCT_GLSL = <<~GLSL
    struct Ray { vec3 origin; vec3 dir; };
    out vec4 fragColor;
    void main() {
      Ray r;
      r.origin = vec3(0.0);
      r.dir = vec3(1.0, 0.0, 0.0);
      fragColor = vec4(r.origin + r.dir, 1.0);
    }
  GLSL

  def test_struct_fields_become_positional_array_indices
    src = transpile(STRUCT_GLSL)
    # default-valued struct: 2 vec3 fields, each its own rt.construct default
    assert_includes src, "r = [rt.construct(3, 0.0), rt.construct(3, 0.0)]"
    assert_includes src, "r[0] = rt.construct(3, rt.f(0))"
    assert_includes src, "r[1] = rt.construct(3, rt.f(1), rt.f(0), rt.f(0))"
    assert_includes src, "r[0]"
    assert_includes src, "r[1]"
  end

  ARRAY_GLSL = <<~GLSL
    out vec4 fragColor;
    void main() {
      float taps[3];
      taps[0] = 1.0;
      taps[1] = 2.0;
      taps[2] = 3.0;
      float total = 0.0;
      for (int i = 0; i < 3; i++) {
        total += taps[i];
      }
      fragColor = vec4(total, 0.0, 0.0, 1.0);
    }
  GLSL

  def test_glsl_array_declarations_use_new_array_and_index_stores
    src = transpile(ARRAY_GLSL)
    assert_includes src, "taps = rt.new_array(rt.i(3), 1)"
    # %.17g strips the trailing ".0" (rt.f(1), not rt.f(1.0)) -- same as
    # Perl's sprintf("%.17g", ...), verified byte-for-byte in the report.
    assert_includes src, "taps[(rt.i(0)).to_i] = rt.f(1)"
    assert_includes src, "taps[(i).to_i]"
  end

  DERIV_GLSL = <<~GLSL
    uniform sampler2D inputTex;
    out vec4 fragColor;
    void main() {
      vec2 uv = gl_FragCoord.xy;
      vec2 dx = dFdx(uv);
      vec2 dy = dFdy(uv);
      fragColor = vec4(dx, dy.x, 1.0);
    }
  GLSL

  def test_derivative_calls_set_uses_derivatives_flag
    src = transpile(DERIV_GLSL)
    assert_includes src, "rt.dFdx(uv)"
    assert_includes src, "rt.dFdy(uv)"
    assert_match(/\{ kernel: run_pixel, uses_derivatives: true \}\n\z/, src)
  end

  def test_non_derivative_shader_flag_is_false
    src = transpile(INVERT_GLSL)
    assert_match(/\{ kernel: run_pixel, uses_derivatives: false \}\n\z/, src)
  end

  NESTED_CALL_GLSL = <<~GLSL
    out vec4 fragColor;
    float square(float x) { return x * x; }
    float sumSquares(float a, float b) { return square(a) + square(b); }
    void main() {
      fragColor = vec4(sumSquares(2.0, 3.0), 0.0, 0.0, 1.0);
    }
  GLSL

  def test_nested_function_calls_predeclare_all_lexicals
    src = transpile(NESTED_CALL_GLSL)
    # Every function-holder local (including main__void) is predeclared
    # BEFORE any lambda body, on one line, mirroring Perl's `my ($a, $b,
    # $c);` hoist -- required because Ruby decides local-vs-method-call at
    # parse time from earlier assignments in the source text, and
    # sumSquares calls square before square's own `= lambda do ... end`
    # line appears.
    assert_match(/^ {2}square__float = sumSquares__float_float = main__void = nil$/, src)
    assert_includes src, "square__float.call(a)"
    assert_includes src, "square__float.call(b)"
  end

  WHILE_GLSL = <<~GLSL
    out vec4 fragColor;
    void main() {
      int i = 0;
      float total = 0.0;
      while (i < 4) {
        total += 1.0;
        i++;
      }
      fragColor = vec4(total, 0.0, 0.0, 1.0);
    }
  GLSL

  def test_while_loop_uses_hard_capped_break_idiom
    src = transpile(WHILE_GLSL)
    assert_includes src, "(0..1048575).each do |_wh0|"
    assert_includes src, "unless rt.bool(rt.binary('<', i, rt.i(4)))"
    assert_includes src, "break"
  end

  # ---- uppercase-initial GLSL identifiers must never become bare Ruby
  # identifiers: Ruby treats any bare word starting with an uppercase ASCII
  # letter as a CONSTANT reference (shared cref namespace, "already
  # initialized constant" warnings on re-eval/re-assignment, and a
  # conditionally-assigned one can read a STALE value left by a completely
  # different kernel instead of the hoisted nil). GLSL is case-sensitive and
  # routinely uses uppercase-initial names for scalar "constants" and
  # swizzle-style locals (NUM_SAMPLES, L, C, H, K, ...) and function names. ----

  UPPERCASE_LOCALS_GLSL = <<~GLSL
    out vec4 fragColor;
    float Blend(float a, float b) { return a + b; }
    int Blend(int a, int b) { return a - b; }
    void main() {
      const int NUM_SAMPLES = 4;
      float total = 0.0;
      for (int i = 0; i < NUM_SAMPLES; i++) {
        total += 1.0;
      }
      float L = 0.5;
      float C = 0.25;
      float H = 0.75;
      vec3 lch = vec3(L, C, H);
      float blended = Blend(total, lch.x);
      int K = Blend(3, 4);
      fragColor = vec4(blended, lch.y + lch.z, float(K), 1.0);
    }
  GLSL

  CONDITIONAL_UPPERCASE_GLSL = <<~GLSL
    out vec4 fragColor;
    void main() {
      float L = 1.0;
      if (1 == 2) {
        L = 5.0;
      }
      fragColor = vec4(L, 0.0, 0.0, 1.0);
    }
  GLSL

  def test_uppercase_glsl_locals_and_functions_never_become_ruby_constants
    src = transpile(UPPERCASE_LOCALS_GLSL)
    refute_bare_uppercase_assignment(src)
    # Every uppercase-initial name gets the same underscore-prefix scheme
    # already used for reserved-name collisions.
    assert_includes src, "_NUM_SAMPLES"
    assert_includes src, "_L"
    assert_includes src, "_C"
    assert_includes src, "_H"
    assert_includes src, "_K"
    assert_includes src, "_Blend__float_float"
    assert_includes src, "_Blend__int_int"

    before_object = Object.constants.sort
    before_nm = NoisemakerCpu.constants.sort
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_equal before_object, Object.constants.sort, "eval defined new top-level Ruby constants"
    assert_equal before_nm, NoisemakerCpu.constants.sort, "eval defined new NoisemakerCpu constants"

    # NUM_SAMPLES=4 -> total = 4x(+1.0) = 4.0; blended = Blend(4.0, L=0.5)
    # (float overload) = 4.5; K = Blend(3, 4) (int overload) = -1.
    assert_in_delta 4.5, out[0], 1e-6
    assert_in_delta 1.0, out[1], 1e-6 # lch.y + lch.z = 0.25 + 0.75
    assert_in_delta(-1.0, out[2], 1e-6)
    assert_in_delta 1.0, out[3], 1e-6
  end

  def test_conditional_write_then_read_on_uppercase_local_stays_off_constant_namespace
    src = transpile(CONDITIONAL_UPPERCASE_GLSL)
    refute_bare_uppercase_assignment(src)
    before = Object.constants.sort
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_equal before, Object.constants.sort, "eval defined new top-level Ruby constants"
    # The `if` branch never runs (1 == 2 is false) -- L must read back its
    # hoisted/initial value (1.0), never a stale value from another kernel's
    # eval (which a constant, being process-wide, could expose).
    assert_in_delta 1.0, out[0], 1e-6
  end

  # ---- GLSL locals that spell Ruby KEYWORDS (next, end, begin, self, when,
  # lambda, ...) must never reach a bare Ruby identifier position either --
  # unlike the uppercase case above, Perl never hit this (a GLSL local named
  # `next` becomes Perl's sigiled `$next`, never confusable with the `next`
  # keyword), but an unmangled Ruby local named `next` is a flat SYNTAX
  # ERROR at both the hoist and every assignment ("target cannot be
  # written") -- this is what broke synth/gradient. `next`/`begin`/`end`/
  # `self`/`when`/`lambda` are all syntactically legal GLSL identifiers
  # (GLSL's own keyword list is disjoint from Ruby's), so this is a live
  # bundle-wide risk, not a contrived one. ----

  KEYWORD_LOCALS_GLSL = <<~GLSL
    out vec4 fragColor;
    void main() {
      float next = 1.0;
      float end = 2.0;
      float begin = 3.0;
      float self = 4.0;
      float when = 5.0;
      float lambda = 6.0;
      float total = 0.0;
      for (int i = 0; i < 5; i++) {
        if (i == 2) {
          continue;
        }
        if (i == 4) {
          break;
        }
        total += next + end + begin + self + when + lambda;
      }
      fragColor = vec4(total, next, end, 1.0);
    }
  GLSL

  def test_glsl_keyword_named_locals_never_become_bare_ruby_keywords
    src = transpile(KEYWORD_LOCALS_GLSL)
    RubyVM::AbstractSyntaxTree.parse(src) # would raise SyntaxError pre-fix
    blanked = src.gsub(/'[^']*'/, "''")
    %w[next end begin self when lambda].each do |kw|
      refute_match(/\b#{kw}\s*[-+*\/%&|^]?=(?!=)/, blanked, "#{kw.inspect} appears as a bare assignment target")
    end
    # The loop-control `next`/`break` KEYWORDS (from GLSL continue/break)
    # must still be present, unmangled, as their OWN whole line -- only the
    # GLSL LOCAL named `next` gets renamed (to `_next`), never a `next`/
    # `break` that codegen itself emits for loop control.
    assert(src.each_line.any? { |l| l =~ /\A\s*next\s*\z/ }, "no bare `next` control-flow line found")
    assert(src.each_line.any? { |l| l =~ /\A\s*break\s*\z/ }, "no bare `break` control-flow line found")

    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    # i=0: total=21; i=1: total=42; i=2: continue (skip); i=3: total=63;
    # i=4: break (before the add) -- loop exits with total=63.
    assert_in_delta 63.0, out[0], 1e-6
    assert_in_delta 1.0, out[1], 1e-6 # next
    assert_in_delta 2.0, out[2], 1e-6 # end
    assert_in_delta 1.0, out[3], 1e-6
  end

  # ---- syntax validity across every kernel this test suite generates ----

  ALL_SNIPPETS = [
    INVERT_GLSL, FOR_LOOP_GLSL, OVERLOAD_GLSL, MATRIX_GLSL, STRUCT_GLSL,
    ARRAY_GLSL, DERIV_GLSL, NESTED_CALL_GLSL, WHILE_GLSL,
    UPPERCASE_LOCALS_GLSL, CONDITIONAL_UPPERCASE_GLSL, KEYWORD_LOCALS_GLSL
  ].freeze

  def test_every_emitted_kernel_is_syntactically_valid_ruby
    ALL_SNIPPETS.each do |glsl|
      src = transpile(glsl)
      RubyVM::AbstractSyntaxTree.parse(src)
    rescue SyntaxError => e
      flunk "generated Ruby failed to parse for snippet starting #{glsl[0, 40].inspect}: #{e.message}"
    end
  end

  # ---- end-to-end: eval the emitted Ruby and run it against a stub rt/ctx ----

  def test_end_to_end_invert_matches_the_contract_float_model_canary
    src = transpile(INVERT_GLSL)
    rt = StubRuntime.new
    # Canary input from the port contract's float-model table: [0.2, 0.4,
    # 0.8, 0.5] f32-snapped (as it would be coming out of a real texture),
    # mode != 1 selects the plain `1.0 - rgb` branch.
    color_in = [0.2, 0.4, 0.8, 0.5].map { |v| rt.f32(v) }
    ctx = StubCtx.new(rt, uniforms: { "mode" => 0 }, textures: { "inputTex" => color_in })
    out, uses_deriv = run_kernel(src, ctx)
    assert_equal false, uses_deriv
    expected = [0.80000001, 0.60000002, 0.19999999, 0.5]
    out.each_with_index do |v, idx|
      assert_in_delta expected[idx], v, 1e-7, "channel #{idx}"
    end
  end

  def test_end_to_end_invert_mode1_takes_the_min_branch
    src = transpile(INVERT_GLSL)
    rt = StubRuntime.new
    color_in = [0.2, 0.4, 0.8, 0.5].map { |v| rt.f32(v) }
    ctx = StubCtx.new(rt, uniforms: { "mode" => 1 }, textures: { "inputTex" => color_in })
    out, = run_kernel(src, ctx)
    # mode == 1: min(color.rgb, 1.0 - color.rgb) componentwise.
    inv = color_in.first(3).map { |c| 1.0 - c }
    expected = color_in.first(3).each_index.map { |k| [color_in[k], inv[k]].min }
    expected.each_index { |k| assert_in_delta rt.f32(expected[k]), out[k], 1e-6 }
    assert_in_delta color_in[3], out[3], 1e-6
  end

  def test_end_to_end_for_loop_sums_zero_through_four
    src = transpile(FOR_LOOP_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 10.0, out[0], 1e-6 # 0+1+2+3+4
  end

  def test_end_to_end_while_loop_counts_to_four
    src = transpile(WHILE_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 4.0, out[0], 1e-6
  end

  def test_end_to_end_overloads_resolve_by_argument_type
    src = transpile(OVERLOAD_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 3.0, out[0], 1e-6 # pick(1.0, 2.0) -> float overload -> 1.0+2.0
    assert_in_delta(-1.0, out[1], 1e-6) # pick(3, 4) -> int overload -> 3-4
  end

  def test_end_to_end_matrix_rotate_quarter_turn
    src = transpile(MATRIX_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    # rotate((1,0), 90deg) -> approx (0, 1)
    assert_in_delta 0.0, out[0], 1e-5
    assert_in_delta 1.0, out[1], 1e-5
  end

  def test_end_to_end_struct_field_access
    src = transpile(STRUCT_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 1.0, out[0], 1e-6
    assert_in_delta 0.0, out[1], 1e-6
    assert_in_delta 0.0, out[2], 1e-6
  end

  def test_end_to_end_array_taps_sum
    src = transpile(ARRAY_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 6.0, out[0], 1e-6 # 1+2+3
  end

  def test_end_to_end_nested_function_calls
    src = transpile(NESTED_CALL_GLSL)
    rt = StubRuntime.new
    ctx = StubCtx.new(rt, uniforms: {})
    out, = run_kernel(src, ctx)
    assert_in_delta 13.0, out[0], 1e-6 # 2^2 + 3^2
  end

  def test_end_to_end_inout_call_nested_in_expression
    src = transpile(<<~GLSL)
      out vec4 fragColor;
      float advance(inout float seed) {
        seed += 1.0;
        return seed * 2.0;
      }
      void main() {
        float seed = 1.0;
        float value = advance(seed) * 3.0;
        fragColor = vec4(value, seed, 0.0, 1.0);
      }
    GLSL
    out, = run_kernel(src, StubCtx.new(StubRuntime.new, uniforms: {}))
    assert_equal [12.0, 2.0, 0.0, 1.0], out
  end

  private

  def transpile(source, defines: {})
    norm = Preprocess.normalize(source, defines)
    ast = Parser.parse(norm["source"])
    Codegen.emit_ruby(ast, norm["outputs"], norm["varyings"])
  end

  # Fails if any emitted line assigns to a bare identifier that starts with
  # an uppercase ASCII letter -- Ruby would parse that as a CONSTANT
  # assignment instead of a local variable. Blanks out single-quoted string
  # contents first so string hash keys / rt method-name args (e.g.
  # `g['TAU']`, `rt.binary('+', ...)`) never trigger a false positive; skips
  # the leading `# Generated by ...` comment line for the same reason
  # (NoisemakerCpu::Transpiler is prose, not code).
  def refute_bare_uppercase_assignment(src)
    src.each_line do |line|
      next if line.lstrip.start_with?("#")

      blanked = line.gsub(/'[^']*'/, "''")
      next unless blanked =~ /\b[A-Z]\w*\s*[-+*\/%&|^]?=(?!=)/

      flunk "emitted line assigns a bare uppercase identifier (Ruby would treat it as a " \
            "constant, not a local): #{line.inspect}"
    end
  end

  def run_kernel(ruby_src, ctx)
    result = eval(ruby_src, TOPLEVEL_BINDING.dup, "test_kernel") # rubocop:disable Security/Eval
    assert_kind_of Hash, result
    assert result[:kernel].respond_to?(:call), "kernel hash missing a callable :kernel"
    out = [0.0, 0.0, 0.0, 0.0]
    result[:kernel].call(ctx, out)
    [out, result[:uses_derivatives]]
  end
end
