# frozen_string_literal: true

# GLSL AST -> Ruby kernel source.
#
# Emits a kernel file whose last expression is `{ kernel: run_pixel,
# uses_derivatives: true|false }` where run_pixel is a lambda called as
# run_pixel.call(ctx, out). The kernel calls the noisemaker_cpu Runtime
# (ctx.rt) with the SAME primitive sequence the (parity-proven) Perl/Python
# codegens emit, so the float model carries over op-for-op.
#
# Ruby-specific emission notes:
# - Ruby locals are lambda/block-scoped the same way Perl's `my` is
#   block-scoped (a `.each do |x| ... end` loop body is its own scope, same
#   as a Perl `{ }` block) -- and Python locals are function-scoped. All body
#   locals are therefore hoisted -- as `name = nil` predeclarations at
#   function top -- and the body emits plain assignments, matching Python's
#   semantics exactly (including its deliberate conflation of GLSL shadowed
#   redeclarations). Ruby also needs the SAME predeclaration for the nested
#   function-holder locals themselves (`main__void = nil` before any lambda
#   that might call it is assigned) since Ruby decides local-vs-method-call
#   at parse time from earlier assignments in the source text, not at
#   runtime.
# - In-place vector reassignment is emitted as `x.replace(rhs)` (float stores
#   go through `.replace(rhs.map { |c| rt.f32(c) })`), preserving JS
#   pooled-array aliasing (`prevUV = rayUV` tracks later updates -- the
#   parallax fix) exactly as Perl's `@{$x} = @{rhs}` does. Confirmed against
#   perl's actual committed kernels (filter/parallax, filter/bulge,
#   classicNoisedeck/bitEffects): EVERY reassignment of an existing
#   width>1 plain-identifier target uses this in-place form, including the
#   final `fragColor` store -- see the report for why this differs from the
#   port contract's illustrative (aliasing-irrelevant) `invert` snippet.
# - Ruby trap #1 (0 is truthy in Ruby): every condition context this codegen
#   emits (if/unless, while-style loop-cap breaks, ternary, &&, ||, !) wraps
#   the GLSL-bool expression in `rt.bool(...)`; GLSL bool VALUES stay Integer
#   0/1 exactly like Perl. This file's OWN Ruby logic (widths, "was this
#   array non-empty", "has this branch been taken") has the same trap one
#   level down -- e.g. Perl's `width_of` returns 1 for a falsy-but-real
#   width of 0 (void) via `$t->{width} || 1`; naively porting `t['width'] ||
#   1` would keep 0 in Ruby (0 is truthy) -- so those checks are written
#   with explicit `!= 0` / `.empty?` / `.nil?` tests throughout, never a bare
#   `if maybe_zero`.

require_relative "lexer"
require_relative "parser"

module NoisemakerCpu
  module Transpiler
    class Codegen
      TYPE = {
        "void" => { "base" => "void", "width" => 0 },
        "bool" => { "base" => "bool", "width" => 1 },
        "int" => { "base" => "int", "width" => 1 },
        "uint" => { "base" => "uint", "width" => 1 },
        "float" => { "base" => "float", "width" => 1 },
        "vec2" => { "base" => "float", "width" => 2 },
        "vec3" => { "base" => "float", "width" => 3 },
        "vec4" => { "base" => "float", "width" => 4 },
        "ivec2" => { "base" => "int", "width" => 2 },
        "ivec3" => { "base" => "int", "width" => 3 },
        "ivec4" => { "base" => "int", "width" => 4 },
        "uvec2" => { "base" => "uint", "width" => 2 },
        "uvec3" => { "base" => "uint", "width" => 3 },
        "uvec4" => { "base" => "uint", "width" => 4 },
        "bvec2" => { "base" => "bool", "width" => 2 },
        "bvec3" => { "base" => "bool", "width" => 3 },
        "bvec4" => { "base" => "bool", "width" => 4 },
        "mat2" => { "base" => "float", "width" => 4, "mat" => 2 },
        "mat3" => { "base" => "float", "width" => 9, "mat" => 3 },
        "mat4" => { "base" => "float", "width" => 16, "mat" => 4 },
        "sampler2D" => { "base" => "sampler", "width" => 0 },
        "sampler3D" => { "base" => "sampler", "width" => 0 },
        "samplerCube" => { "base" => "sampler", "width" => 0 },
        "sampler2DArray" => { "base" => "sampler", "width" => 0 },
      }.freeze
      FLOAT = TYPE["float"]
      BOOL = TYPE["bool"]
      VEC4 = TYPE["vec4"]

      # Names that would collide with emitted-kernel infrastructure locals,
      # PLUS every identifier-shaped Ruby keyword. Perl never had this
      # problem (Perl scalars carry a `$` sigil, so a GLSL local named
      # `next` becomes `$next` -- never confusable with Perl's own `next`
      # keyword); Ruby locals are bare words, so a GLSL local named `next`
      # emitted unmangled is a Ruby SYNTAX ERROR at both the hoist (`next =
      # nil`) and every assignment ("target cannot be written") -- observed
      # live in synth/gradient. The keyword list below is Ruby's full
      # reserved-word set restricted to identifier-shaped entries (`defined?`
      # carries a `?` and is not a legal GLSL identifier to begin with, so
      # it is omitted -- nothing to collide with). `lambda`/`proc` are not
      # keywords but ARE reserved here: the emitted kernel ABI calls bare
      # `lambda do ... end`, and a GLSL local named `lambda` would shadow
      # Kernel#lambda into a NoMethodError on the next nested function def.
      # `p` is deliberately NOT reserved -- Ruby's Kernel#p is legally
      # shadowed by a local of the same name with no behavioral effect, a
      # live bundle scan found 73 kernels using a GLSL local literally
      # named `p`, and all 73 already compile and pass parity byte-exact;
      # reserving it would churn 73 generated files for zero behavior change.
      # Ruby's `U` uniform casing (not Perl's `U`) and lack of a `T` textures
      # map are covered by the ABI's own lowercase `u`; `t` is kept as a
      # harmless defensive reservation mirroring Perl's own vestigial `T`
      # entry (Perl's ABI never defines $T either).
      RESERVED = (%w[rt g u t ctx out kernel run_pixel lambda proc] + %w[
        alias and begin break case class def do else elsif end ensure false
        for if in module next nil not or redo retry rescue return self super
        then true undef unless until when while yield BEGIN END
        __FILE__ __LINE__ __ENCODING__
      ]).each_with_object({}) { |n, h| h[n] = true }.freeze

      # Ruby treats any bare identifier starting with an uppercase ASCII
      # letter as a CONSTANT reference, never a local variable -- constants
      # are not lexically/binding-scoped the way locals are (they resolve
      # against the shared cref, land in one namespace across every
      # separately-eval'd kernel, warn "already initialized constant" on
      # re-assignment/re-eval, and a conditionally-assigned one reads a
      # STALE value from a DIFFERENT kernel rather than the hoisted nil when
      # its own assignment didn't run). GLSL identifiers are case-sensitive
      # and routinely start uppercase (`NUM_SAMPLES`, `L`, `C`, `H`, `K`,
      # `MAX_OCT`, a user function literally named `Foo`, ...) -- mangle
      # those with the SAME underscore-prefix scheme already used for
      # reserved-name collisions, so the result is always a lowercase-class
      # (local-variable-shaped) Ruby identifier. This only matters for BARE
      # identifiers (locals, params, function-holder names); string hash
      # keys (`g['TAU']`) are never at risk and are deliberately left
      # untouched -- see the `g[...]` construction in `emit`.
      def self.p_ident(name)
        (RESERVED[name] || name =~ /\A[A-Z]/) ? "_#{name}" : name
      end

      def self.base_of(t)
        t && t["base"] ? t["base"] : "float"
      end

      # Perl: `($t && $t->{width}) ? $t->{width} : 1` -- width CAN legitimately
      # be 0 (the void type), which is falsy in Perl (so `width_of(void)` is
      # 1, not 0) but truthy in Ruby -- so this needs an explicit `!= 0`,
      # not a bare `t["width"] ? ... : 1`.
      def self.width_of(t)
        w = t && t["width"]
        w && w != 0 ? w : 1
      end

      # single-quoted Ruby string literal
      def self.rq(s)
        "'#{s.to_s.gsub(/(['\\])/, '\\\\\\\1')}'"
      end

            # Split a generated argument list at top-level commas (parens/brackets
                  # and single-quoted strings respected) -- used to turn a construct call
                  # back into sequential component assignments for JS comma-assign
                  # aliasing semantics.
                  def self.split_top_args(s)
                    out = []
                    depth = 0
                    cur = +""
                    in_str = false
                    s.each_char do |ch|
                      if in_str
                        cur << ch
                        in_str = false if ch == "'"
                      elsif ch == "'"
                        in_str = true
                        cur << ch
                      elsif ch == "(" || ch == "["
                        depth += 1
                        cur << ch
                      elsif ch == ")" || ch == "]"
                        depth -= 1
                        cur << ch
                      elsif ch == "," && depth.zero?
                        out << cur.strip
                        cur = +""
                      else
                        cur << ch
                      end
                    end
                    out << cur.strip unless cur.strip.empty?
                    out
                  end

                  # JS comma-assign semantics for `dst = <construct-shaped rhs>`: the
                  # compiled kernel stores components sequentially, so a later element
                  # may read target components already overwritten (e.g. sdfTriangle's
                  # `p = vec2((p.x - k*p.y)/2, (-k*p.x - p.y)/2)` compiles to
                  # `p[0] = (p[0] - k*p[1])/2, p[1] = (-k*p[0] - p[1])/2` where p[1]
                  # reads the NEW p[0]). Returns sequential store code, or nil when the
                  # rhs is not a plain (or scalar-wrapped elementwise) construct.
                  def self._scalar_code?(s)
                    !s.include?(",") && (s.match?(/\Art\.[fi]\(/) || s.match?(/\A-?[\d.]+(e[+-]?\d+)?\z/i))
                  end

                  def self._construct_elems(rhs)
                    m = /\Art\.construct\((\d+), (.*)\)\z/m.match(rhs)
                    return nil unless m

                    w = m[1].to_i
                    elems = split_top_args(m[2])
                    w >= 1 && elems.length == w ? [w, elems] : nil
                  end

                  def self._sequential_assign(tcode, rhs)
                    base = _construct_elems(rhs)
                    if base
                      w, elems = base
                      return nil if w <= 1

                      # The generator's preserveVectorAssignmentReads temps
                      # ONLY single-line constructor self-assigns (mirrored in
                      # build.rb); every other whole-assign lowers to the JS
                      # comma-assign where later components read the
                      # ALREADY-STORED earlier components (mandelbrot's
                      # dz.y reads the new dz.x). So self-references here are
                      # resolved SEQUENTIALLY, not snapshot.
                      return elems.each_with_index.map { |e, i| "#{tcode}[#{i}] = rt.f32(#{e})" }.join("; ")
                    end
                    m = /\Art\.binary\((.*)\)\z/m.match(rhs)
                    return nil unless m

                    parts = split_top_args(m[1])
                    return nil unless parts.length == 5 && parts[4] == "'float'" && parts[3].match?(/\A\d+\z/)

                    op, lhs, rhs2 = parts[0], parts[1], parts[2]
                    [[lhs, rhs2], [rhs2, lhs]].each do |operand, other|
                      base = _construct_elems(operand)
                      next if base.nil?

                      w, elems = base
                      next unless w == parts[3].to_i && w > 1 && _scalar_code?(other)

                      return elems.each_with_index.map do |e, i|
                        "#{tcode}[#{i}] = rt.f32(rt.binary(#{op}, #{e}, #{other}, 1, 'float'))"
                      end.join("; ")
                    end
                    nil
                  end

      def self._fmt_num(raw)
        # Ruby's format("%.17g", ...) matches Perl's sprintf("%.17g", ...)
        # byte-for-byte (verified against libc snprintf on the same
        # platform), so a value round-trips to the identical textual literal
        # Perl's codegen would emit -- required by the port contract's "never
        # reformat floats" rule.
        format("%.17g", raw.to_f)
      end

      def self._construct_base(t)
        t && (t["base"] == "int" || t["base"] == "uint") ? ", #{rq(t["base"])}" : ""
      end

      def self._type_name(t)
        TYPE.keys.sort.each do |k|
          v = TYPE[k]
          if (v["base"] || "") == (t["base"] || "") &&
             (v["width"] || 0) == (t["width"] || 0) &&
             (v["mat"] || 0) == (t["mat"] || 0)
            return k
          end
        end
        "#{base_of(t)}#{width_of(t)}"
      end

      # ---- scope ----
      class Scope
        attr_reader :parent, :vars

        def initialize(parent)
          @parent = parent
          @vars = {}
        end

        def child
          Scope.new(self)
        end

        def define(name, typ, rbname = nil)
          entry = { "py" => rbname || Codegen.p_ident(name), "type" => typ }
          @vars[name] = entry
          entry
        end

        def resolve(name)
          s = self
          while s
            return s.vars[name] if s.vars.key?(name)

            s = s.parent
          end
          nil
        end
      end

      # Functions whose GLSL definitions are overridden by runtime routing.
      SKIP_FUNCS = %w[cpu_umul cpu_ivec2 cpu_ivec3 cpu_ivec4 cpu_uvec2 cpu_uvec3 cpu_uvec4 cpu_float]
                   .each_with_object({}) { |n, h| h[n] = true }.freeze

      def self.emit_ruby(program, outputs, varyings)
        program["decls"] = program["decls"].reject { |d| (d["k"] || "") == "func" && SKIP_FUNCS[d["name"] || ""] }
        new(program, outputs, varyings).emit
      end

      def initialize(program, outputs, varyings)
        @program = program
        @outputs = outputs && !outputs.empty? ? outputs : ["fragColor"]
        @varyings = {}
        (varyings || []).each { |v| @varyings[v] = true }
        @root = Scope.new(nil)
        @overloads = {} # base name -> [ {mangled, ptypes, ret, node, out_idxs} ]
        @funcs = []
        @uniforms = [] # [{name, type}]
        @globals = [] # [{name, type, init, array}]
        @structs = {} # name -> [ [fieldtype, fieldname], ... ]
        @loop_id = 0
        @uses_deriv = false
        @cur_out = [] # out/inout param rbnames of the function being emitted
        @declared = nil # per-function set of hoisted local names
        @unused_n = 0
        @in_vec_assign = false # see _e_binary's scalar-vec raw-coercion note
        @in_vec_whole_assign = false # whole-vector (not per-slot) assign ctx
        @vec_assign_root = false # top-level rhs of the current assign
      end

      # ---- collect ----
      def collect
        @program["decls"].each do |d|
          case d["k"]
          when "struct"
            @structs[d["name"]] = d["fields"].map { |f| [f[0], f[1]] }
          when "func"
            _collect_func(d)
          when "proto"
            # nothing to collect
          when "decl"
            _collect_decl(d)
          when "ubo"
            # Anonymous std140 block members are addressed like bare uniforms.
            d["members"].each do |m|
              @uniforms << { "name" => m["name"], "type" => type_of_name(m["type"], m["array"]) }
            end
          end
        end
      end

      def type_of_name(tname, array = nil)
        t = (TYPE[tname] || { "base" => "float", "width" => 1 }).dup
        t = { "base" => "struct", "width" => 0, "struct" => tname } if @structs[tname]
        unless array.nil?
          t = t.dup
          t["array"] = 1
        end
        t
      end

      def _collect_func(d)
        ret = type_of_name(d["ret"])
        ptypes = d["params"].map { |p| type_of_name(p[0]) }
        out_idxs = []
        d["params"].each_index do |i|
          p = d["params"][i]
          out_idxs << i if p[2] && (p[2].include?("out") || p[2].include?("inout"))
        end
        mangled = "#{Codegen.p_ident(d["name"])}__#{ptypes.empty? ? "void" : ptypes.map { |t| Codegen._type_name(t) }.join("_")}"
        entry = { "mangled" => mangled, "ptypes" => ptypes, "ret" => ret, "node" => d, "out_idxs" => out_idxs }
        @funcs << entry
        (@overloads[d["name"]] ||= []) << entry
      end

      def _collect_decl(d)
        quals = d["quals"] || []
        if quals.include?("uniform")
          d["declarators"].each do |dc|
            @uniforms << { "name" => dc["name"], "type" => type_of_name(d["type"]) }
          end
        else
          d["declarators"].each do |dc|
            @globals << {
              "name" => dc["name"],
              "type" => type_of_name(d["type"], dc["array"]),
              "init" => dc["init"],
              "array" => dc["array"],
            }
          end
        end
      end

      # ---- emit ----
      def emit
        collect
        @uniforms.each { |u| @root.define(u["name"], u["type"], "_u_#{Codegen.p_ident(u["name"])}") }
        @globals.each do |g|
          # String hash key -- never a bare Ruby identifier, so it is never
          # at risk of the uppercase-constant trap and is left unmangled
          # (raw GLSL name), same as every other g['...'] site below.
          rb = @varyings[g["name"]] ? "ctx.uv" : "g['#{g["name"]}']"
          @root.define(g["name"], g["type"], rb)
        end

        l = [
          "run_pixel = lambda do |ctx, out|",
          "  rt = ctx.rt",
          "  u = ctx.uniforms",
          "  g = {}",
        ]
        fn_lexicals = @funcs.map { |fn| fn["mangled"] }
        l << "  #{fn_lexicals.join(" = ")} = nil" unless fn_lexicals.empty?
        l << "  _retc = nil"
        @uniforms.each do |uu|
          n = Codegen.p_ident(uu["name"])
          if Codegen.base_of(uu["type"]) == "sampler"
            l << "  _u_#{n} = ctx.texture_binding(#{Codegen.rq(uu["name"])})"
          else
            # WebGL zero-initializes unbound uniforms; default absent ones.
            l << "  _u_#{n} = u.key?(#{Codegen.rq(uu["name"])}) ? u[#{Codegen.rq(uu["name"])}] : #{_default(uu["type"])}"
          end
        end
        @globals.each do |gg|
          next if @varyings[gg["name"]]

          code =
            if !gg["init"].nil?
              expr(gg["init"], @root)[0]
            elsif !gg["array"].nil?
              n_code = gg["array"].is_a?(Hash) ? expr(gg["array"], @root)[0] : "0"
              "rt.new_array(#{n_code}, #{gg["type"]["width"]})"
            else
              _default(gg["type"])
            end
          l << "  g['#{gg["name"]}'] = #{code}"
        end

        main = nil
        @funcs.each do |fn|
          if fn["node"]["name"] == "main"
            main = fn
            next
          end
          _emit_func(l, fn)
        end
        raise "shader has no main()\n" if main.nil?

        _emit_func(l, main)
        l << "  #{main["mangled"]}.call"
        @outputs.each_with_index do |output_name, output_index|
          value = @varyings[output_name] ? "ctx.uv" : "g['#{output_name}']"
          local = @outputs.length == 1 ? "c" : "c#{output_index}"
          base = output_index * 4
          l << "  #{local} = #{value}"
          l << "  out[#{base}] = rt.f32(#{local}[0]); out[#{base + 1}] = rt.f32(#{local}[1]); " \
               "out[#{base + 2}] = rt.f32(#{local}[2]); out[#{base + 3}] = rt.f32(#{local}[3])"
        end
        l << "end"
        trailer = "{ kernel: run_pixel, uses_derivatives: #{@uses_deriv ? "true" : "false"}"
        trailer += ", output_names: #{@outputs.inspect}" if @outputs.length > 1
        l << "#{trailer} }"
        (["# Generated by NoisemakerCpu::Transpiler - do not edit."] + l).join("\n") + "\n"
      end

      def _emit_func(l, fn)
        indent = 1
        pad = "  " * indent
        scope = @root.child
        rbnames = []
        fn["node"]["params"].each_index do |i|
          p = fn["node"]["params"][i]
          t = fn["ptypes"][i]
          if p[1].nil?
            @unused_n += 1
            rbnames << "_unused#{@unused_n}"
            next
          end
          rbnames << scope.define(p[1], t)["py"]
        end
        body_head = []
        fn["node"]["params"].each_index do |i|
          p = fn["node"]["params"][i]
          t = fn["ptypes"][i]
          next unless p[1] && Codegen.width_of(t) > 1

          v = Codegen.p_ident(p[1])
          body_head << "#{pad}  #{v} = rt.copy(#{v}, #{Codegen.rq(Codegen.base_of(t))})"
        end
        out_rbnames = (fn["out_idxs"] || []).map { |i| rbnames[i] }
        prev_out = @cur_out
        prev_decl = @declared
        @cur_out = out_rbnames
        @declared = {}
        rbnames.each { |n| @declared[n] = true }
        body = block(fn["node"]["body"], scope, indent + 1)
        body << "#{pad}  return [nil, #{out_rbnames.join(", ")}]" unless out_rbnames.empty?
        locals = (@declared.keys - rbnames).sort
        @cur_out = prev_out
        @declared = prev_decl
        params_src = rbnames.empty? ? "" : " |#{rbnames.join(", ")}|"
        l << "#{pad}#{fn["mangled"]} = lambda do#{params_src}"
        l.concat(body_head)
        l << "#{pad}  #{locals.map { |n| "#{n} = nil" }.join("; ")}" unless locals.empty?
        l.concat(body)
        l << "#{pad}end"
      end

      # Register a body local; returns the rbname. All body locals are
      # hoisted to one `name = nil; ...` predeclaration at function top
      # (Python function-scope semantics; see the file header comment).
      def _local(rbname)
        @declared[rbname] = true if @declared
        rbname
      end

      def block(stmts, scope, indent)
        out = []
        stmts.each { |s| stmt(s, scope, indent, out) }
        out
      end

      def stmt(s, scope, indent, out)
        pad = "  " * indent
        k = s["k"]
        case k
        when "block"
          out.concat(block(s["body"], scope.child, indent))
        when "decl"
          s["declarators"].each do |dc|
            t = type_of_name(s["type"], dc["array"])
            # Resolve the initializer in the ENCLOSING scope, before the new
            # name is defined (GLSL `float time = time;` reads the outer time).
            init = dc["init"]
            init_code =
              if init.nil?
                nil
              elsif (tid = _restore_integer_division(init, scope))
                tid
              else
                expr(init, scope)[0]
              end
            e = scope.define(dc["name"], t)
            _local(e["py"])
            if !init_code.nil?
              # A float-vector declaration whose initializer is arithmetic
              # compiles in the oracle to a pooled-array CONSTRUCTOR of RAW
              # scalar-slot JS expressions: `var u = new PooledFloat32Array(
              # [(f[0]*f[0])*(3-2*f[0]), (f[1]*f[1])*(3-2*f[1])])` — f64
              # arithmetic with a SINGLE f32 round at the store (vnoise's u).
              # Routing the whole rhs through one rt.binary would f32-round
              # every intermediate (1-ulp drift amplified by hash math:
              # craquelure seed-7/size-16). Project per-component like the
              # comma-assign path; fall back to the once-eval construct when
              # any slot needs a whole-vector call result (runtime calls/
              # textures are hoisted, never re-inlined per slot).
              if Codegen.base_of(t) == "float" && Codegen.width_of(t) > 1 && !t["mat"] && dc["init"]["k"] != "id" && dc["init"]["k"] != "construct"
                slots = (0...Codegen.width_of(t)).map { |ci| _vec_comp(dc["init"], scope, ci) }
                if slots.all? { |sc, st| Codegen.width_of(st) == 1 && !sc.start_with?("(begin ") && !sc.match?(/\bcall\(/) && !sc.start_with?("rt.texture") && !sc.match?(/\Art\.(?!binary\b|f\b|i\b|swizzle\b|construct\b|component_wise\b)/) }
                  init_code = "rt.construct(#{t["width"]}, #{slots.map { |sc, _| sc }.join(", ")})"
                else
                  init_code = "rt.construct(#{t["width"]}, #{init_code})"
                end
              elsif Codegen.base_of(t) == "float" && Codegen.width_of(t) > 1 && !t["mat"] && dc["init"]["k"] != "id"
                init_code = "rt.construct(#{t["width"]}, #{init_code})"
              end
              # GLSL `vecN v = u;` copies. The JS generator emits a live alias
              # (`var z = pos;`) unless its copy pass rewrites the statement;
              # scripts/upstream/compile-glsl.js (CPU 390071f) now copies
              # single-statement `var NAME = IDENT;` declarations inside
              # function bodies (scalars and self-references pass through,
              # multi-declarator lines do not match), and the regenerated
              # canonical kernels carry the copies. Mirror the same value copy
              # here for vector/matrix declarations: a later component-wise
              # write to the copy (mandelbulb's `z[0] = ...` recurrence in
              # synth3d/fractal3d) must not destroy the initializer.
              if s["declarators"].length == 1 && dc["init"]["k"] == "id" &&
                 dc["init"]["name"] != dc["name"] && (Codegen.width_of(t) > 1 || t["mat"])
                init_code = "rt.copy(#{init_code}, #{Codegen.rq(Codegen.base_of(t))})"
              end
              out << "#{pad}#{e["py"]} = #{init_code}"
            elsif !dc["array"].nil?
              n_code = dc["array"].is_a?(Hash) ? expr(dc["array"], scope)[0] : "0"
              out << "#{pad}#{e["py"]} = rt.new_array(#{n_code}, #{t["width"]})"
            else
              out << "#{pad}#{e["py"]} = #{_default(t)}"
            end
          end
        when "expr"
          code, = expr(s["expr"], scope)
          out << "#{pad}#{code}"
        when "if"
          code, = expr(s["cond"], scope)
          # Hoist lowered-#if branch declarations to the enclosing scope (see
          # the Perl/Python codegen for the full rationale).
          hoist = _branch_decls(s["then"]).dup
          hoist.merge!(_branch_decls(s["els"])) unless s["els"].nil?
          hoist.keys.sort.each do |name|
            next if scope.resolve(name)

            e = scope.define(name, hoist[name])
            _local(e["py"])
            out << "#{pad}#{e["py"]} = #{_default(hoist[name])}"
          end
          out << "#{pad}if #{_bool(code)}"
          out.concat(_branch(s["then"], scope, indent + 1))
          unless s["els"].nil?
            out << "#{pad}else"
            out.concat(_branch(s["els"], scope, indent + 1))
          end
          out << "#{pad}end"
        when "for"
          _for(s, scope, indent, out)
        when "while", "dowhile"
          lid = @loop_id
          @loop_id += 1
          out << "#{pad}(0..1048575).each do |_wh#{lid}|"
          code, = expr(s["cond"], scope)
          out << "#{pad}  unless #{_bool(code)}"
          out << "#{pad}    break"
          out << "#{pad}  end"
          out.concat(_branch(s["body"], scope.child, indent + 1))
          out << "#{pad}end"
        when "return"
          val_node = s["value"]
          # GLSL permits `return x = expr;` -- hoist the assignment.
          if !val_node.nil? && (val_node["k"] || "") == "assign"
            stmt_code, = _e_assign(val_node, scope)
            out << "#{pad}#{stmt_code}"
            val_node = val_node["target"]
          end
          if !@cur_out.empty?
            val = val_node.nil? ? "nil" : expr(val_node, scope)[0]
            out << "#{pad}return [#{val}, #{@cur_out.join(", ")}]"
          elsif val_node.nil?
            out << "#{pad}return"
          else
            code, vt = expr(val_node, scope)
            # A float-vector RETURN of arithmetic compiles in the oracle to
            # `return new PooledFloat32Array([raw scalar slots...])` — f64
            # math per component with ONE f32 round at the array store
            # (taylorInvSqrt: 1.79284291400159 - 0.8537347208*r[k] — the
            # product stays unrounded). Emitting the whole-expression
            # rt.binary vector chain f32-rounds every intermediate. Project
            # per-component like the decl-initializer path above.
            if Codegen.base_of(vt) == "float" && Codegen.width_of(vt) > 1 && !vt["mat"] &&
               (val_node["k"] == "binary" || val_node["k"] == "unary" || val_node["k"] == "cond")
              slots = (0...Codegen.width_of(vt)).map { |ci| _vec_comp(val_node, scope, ci) }
              ok = slots.all? { |sc, st| Codegen.width_of(st) == 1 && !sc.start_with?("(begin ") && !sc.match?(/\bcall\(/) && !sc.start_with?("rt.texture") && !sc.match?(/\Art\.(?!binary\b|f\b|i\b|swizzle\b|construct\b|component_wise\b|unary\b)/) }
              code = "rt.construct(#{vt["width"]}, #{slots.map(&:first).join(", ")})" if ok
            end
            out << "#{pad}return #{code}"
          end
        when "break"
          out << "#{pad}break"
        when "continue"
          out << "#{pad}next"
        when "discard"
          out << "#{pad}return"
        else
          raise "codegen: unhandled statement #{k}\n"
        end
      end

      def _branch(s, scope, indent)
        out = []
        if s["k"] == "block"
          out.concat(block(s["body"], scope.child, indent))
        else
          stmt(s, scope.child, indent, out)
        end
        out
      end

      # Names (mapped to type) a branch may declare at its top level -- the
      # UNION over if/elif/else arms, for hoisting lowered-#if declarations.
      def _branch_decls(s)
        return {} if s.nil?

        k = s["k"] || ""
        case k
        when "block"
          decls = {}
          s["body"].each do |st|
            next unless (st["k"] || "") == "decl"

            st["declarators"].each { |dc| decls[dc["name"]] = type_of_name(st["type"], dc["array"]) }
          end
          decls
        when "decl"
          s["declarators"].each_with_object({}) { |dc, h| h[dc["name"]] = type_of_name(s["type"], dc["array"]) }
        when "if"
          d = _branch_decls(s["then"]).dup
          d.merge!(_branch_decls(s["els"]))
          d
        else
          {}
        end
      end

      def _for(s, scope, indent, out)
        pad = "  " * indent
        lid = @loop_id
        @loop_id += 1
        ls = scope.child
        stmt(s["init"], ls, indent, out) if s["init"]
        _local("_for#{lid}_first")
        out << "#{pad}_for#{lid}_first = true"
        out << "#{pad}(0..1048575).each do |_for#{lid}|"
        out << "#{pad}  unless _for#{lid}_first"
        if s["update"]
          code, = expr(s["update"], ls)
          out << "#{pad}    #{code}"
        end
        out << "#{pad}  end"
        out << "#{pad}  _for#{lid}_first = false"
        if s["cond"]
          code, = expr(s["cond"], ls)
          out << "#{pad}  unless #{_bool(code)}"
          out << "#{pad}    break"
          out << "#{pad}  end"
        end
        out.concat(_branch(s["body"], ls, indent + 1))
        out << "#{pad}end"
      end

      def _default(t)
        if Codegen.base_of(t) == "struct"
          fields = @structs[t["struct"]] || []
          return "[#{fields.map { |f| _default(type_of_name(f[0])) }.join(", ")}]"
        end
        if Codegen.width_of(t) == 1
          return Codegen.base_of(t) == "bool" ? "0" : (Codegen.base_of(t) == "int" || Codegen.base_of(t) == "uint") ? "0" : "rt.f(0.0)"
        end
        "rt.construct(#{t["width"]}, 0.0#{Codegen._construct_base(t)})"
      end

      # Wrap a GLSL-bool-valued expression's Ruby text for use as a Ruby
      # condition (if/unless/ternary/&&/||/!) -- Ruby trap #1 (see file
      # header). GLSL bool VALUES themselves stay Integer 0/1; only the
      # condition SITE gets wrapped.
      def _bool(code)
        "rt.bool(#{code})"
      end

      # ---- expressions -> [code, type] ----
      def expr(node, scope)
        k = node["k"]
        m = "_e_#{k}"
        raise "codegen: no handler for expr kind #{k}\n" unless respond_to?(m, true)

        code, typ = send(m, node, scope)
        [code, typ]
      end

      def _e_num(node, _scope)
        raw = node["value"]
        low = raw.downcase
        if low.end_with?("u")
          body = raw.sub(/[uU]\z/, "")
          v = body =~ /\A0[xX]/ ? body.to_i(16) : body.to_i
          return ["rt.i(#{v})", TYPE["uint"]]
        end
        if low.start_with?("0x")
          return ["rt.i(#{raw.to_i(16)})", TYPE["int"]]
        end
        if raw.include?(".") || low.include?("e") || low.end_with?("f")
          body = raw.sub(/[fF]\z/, "")
          # GLSL float literals are rounded to f32 AT PARSE TIME in the oracle
          # (csl Literal -> Math.fround(value)): the JS kernel then adds/muls
          # the f64 double of that f32 value. Emitting the raw f64 decimal
          # (33.329999999999998 for "33.33") would add a DIFFERENT f64 and
          # skew every f32-rounded sum by 1 ulp (craquelure hash12's
          # p3.yzx + 33.33). Snap now: rt.f(f32(33.33)) = rt.f(33.33000183105469).
          f = [body.to_f].pack("e").unpack1("e")
          return ["rt.f(#{Codegen._fmt_num(f)})", FLOAT]
        end
        ["rt.i(#{raw.to_i})", TYPE["int"]]
      end

      def _e_bool(node, _scope)
        [node["value"] != 0 ? "1" : "0", BOOL]
      end

      def _e_id(node, scope)
        name = node["name"]
        return ["ctx.frag_coord", VEC4] if name == "gl_FragCoord"

        e = scope.resolve(name)
        unless e
          return ["ctx.uv", TYPE["vec2"]] if %w[v_texCoord vTexCoord texCoord].include?(name)

          raise "codegen: unresolved identifier '#{name}'\n"
        end
        [e["py"], e["type"]]
      end

      # The oracle's compile-glsl.js restoreIntegerDivision (synced at
      # noisemaker-for-cpu d13b0a2100fb) rewrites statement-level
      # `var name = vec[i] / intName;` declarations to
      # `Math.trunc(vec[i] / intName)`: GLSL int/int division truncates
      # toward zero, but the compiled kernels kept the raw f64 quotient
      # (the volume-atlas `int z = pixelCoord.y / volSize` mapping sampled
      # z = 63.984 where the authority samples z = 63). Mirror the narrowing
      # exactly: declarations only, a component-selected dividend
      # (single-component member or numeric-literal index of an identifier)
      # and a plain int-typed identifier divisor. The CPU repo measured and
      # REJECTED broader expression-level rewrites (filter/spookyTicker's
      # authority bytes contradict the pinned GLSL's int-division semantics;
      # see its GAP-003 record) -- do not widen this rule.
      def _restore_integer_division(init, scope)
        return nil unless init.is_a?(Hash) && init["k"] == "binary" && init["op"] == "/"

        l = init["l"]
        r = init["r"]
        dividend_code =
          if l.is_a?(Hash) && l["k"] == "member" && l["obj"].is_a?(Hash) &&
             l["obj"]["k"] == "id" && l["field"].is_a?(String) && l["field"].length == 1
            obj_code, obj_t = expr(l["obj"], scope)
            return nil unless Codegen.width_of(obj_t) > 1 && Codegen.base_of(obj_t) != "struct"

            "rt.swizzle(#{obj_code}, #{Codegen.rq(l['field'])})"
          elsif l.is_a?(Hash) && l["k"] == "index" && l["obj"].is_a?(Hash) &&
                l["obj"]["k"] == "id" && l["idx"].is_a?(Hash) && l["idx"]["k"] == "num"
            obj_code, obj_t = expr(l["obj"], scope)
            return nil unless Codegen.width_of(obj_t) > 1 && Codegen.base_of(obj_t) != "struct"

            "#{obj_code}[(rt.i(#{l['idx']['value'].to_i})).to_i]"
          else
            return nil
          end
        return nil unless r.is_a?(Hash) && r["k"] == "id"

        re = scope.resolve(r["name"])
        return nil unless re && Codegen.base_of(re["type"]) == "int"

        "rt.trunc_div(#{dividend_code}, #{re['py']})"
      end

      def _e_member(node, scope)
        obj_code, obj_t = expr(node["obj"], scope)
        field = node["field"]
        if Codegen.base_of(obj_t) == "struct"
          fields = @structs[obj_t["struct"]] || []
          idx = 0
          fields.each_index do |i|
            if fields[i][1] == field
              idx = i
              break
            end
          end
          ftype = fields.empty? ? FLOAT : type_of_name(fields[idx][0])
          return ["#{obj_code}[#{idx}]", ftype]
        end
        w = field.length
        t = { "base" => Codegen.base_of(obj_t), "width" => w }
        ["rt.swizzle(#{obj_code}, #{Codegen.rq(field)})", t]
      end

      def _e_index(node, scope)
        obj_code, obj_t = expr(node["obj"], scope)
        idx_code, = expr(node["idx"], scope)
        if obj_t["mat"]
          n = obj_t["mat"]
          return ["rt.mat_col(#{obj_code}, #{idx_code}, #{n})", { "base" => "float", "width" => n }]
        end
        if obj_t["array"]
          # JS array read: fractional indices (possible because the compiled
          # kernels keep `/` as float division) read as undefined.
          return ["rt.array_index(#{obj_code}, #{idx_code})", { "base" => Codegen.base_of(obj_t), "width" => obj_t["width"] }]
        end
        [ "#{obj_code}[(#{idx_code}).to_i]", { "base" => Codegen.base_of(obj_t), "width" => 1 }]
      end

      def _e_unary(node, scope)
        return _incdec(node["x"], node["op"], scope) if node["op"] == "++" || node["op"] == "--"

        code, t = expr(node["x"], scope)
        return ["(#{_bool(code)} ? 0 : 1)", BOOL] if node["op"] == "!"
        return ["rt.bit_not(#{code})", t] if node["op"] == "~"

        ["rt.unary(#{Codegen.rq(node["op"])}, #{code})", t]
      end

      def _e_post(node, scope)
        _incdec(node["x"], node["op"], scope)
      end

      def _incdec(target, op, scope)
        if target["k"] == "index"
          # Array-element ++/-- stays a direct lvalue read-modify-write.
          obj_code, obj_t = expr(target["obj"], scope)
          idx_code, = expr(target["idx"], scope)
          t = { "base" => Codegen.base_of(obj_t), "width" => obj_t["width"], "array" => 1 }
          base = op == "++" ? "+" : "-"
          b = Codegen.base_of(t) == "uint" ? "uint" : (Codegen.base_of(t) == "int" ? "int" : "float")
          cur = "#{obj_code}[(#{idx_code}).to_i]"
          return ["#{cur} = rt.binary(#{Codegen.rq(base)}, #{cur}, rt.i(1), #{Codegen.width_of(t)}, #{Codegen.rq(b)})", t]
        end
        code, t = expr(target, scope)
        base = op == "++" ? "+" : "-"
        b = Codegen.base_of(t) == "uint" ? "uint" : (Codegen.base_of(t) == "int" ? "int" : "float")
        ["#{code} = rt.binary(#{Codegen.rq(base)}, #{code}, rt.i(1), #{Codegen.width_of(t)}, #{Codegen.rq(b)})", t]
      end

      def _e_cond(node, scope)
        c_code, = expr(node["c"], scope)
        a_code, a_t = expr(node["a"], scope)
        b_code, b_t = expr(node["b"], scope)
        w = [Codegen.width_of(a_t), Codegen.width_of(b_t)].max
        ["(#{_bool(c_code)} ? (#{a_code}) : (#{b_code}))", { "base" => Codegen.base_of(a_t), "width" => w }]
      end

      COMPARE_LOGIC_OPS = %w[== != < > <= >= && ||].each_with_object({}) { |o, h| h[o] = true }.freeze
      INT_FORCING_OPS = %w[& | ^ << >> %].each_with_object({}) { |o, h| h[o] = true }.freeze

      # Scalar float literal/literal ops the oracle folds to f32 constants.
      FOLD_OPS = {
        "+" => ->(a, b) { a + b },
        "-" => ->(a, b) { a - b },
        "*" => ->(a, b) { a * b },
        "/" => ->(a, b) { b.zero? ? Float::NAN : a / b },
      }.freeze
      FOLDABLE_OPS = FOLD_OPS.keys.freeze
      LITERAL_F_RE = /\Art\.f\((-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)\)\z/.freeze

      def literal_float_of(code)
        m = LITERAL_F_RE.match(code.strip)
        return nil unless m

        m[1].to_f
      end

      def base_unknown_fold_candidate?(op, l_code, r_code)
        return false unless FOLDABLE_OPS.include?(op)
        return false if l_code.nil? || r_code.nil?

        literal_float_of(l_code) && literal_float_of(r_code) ? true : false
      end

      def _e_binary(node, scope)
        op = node["op"]
        was_root = @vec_assign_root
        saved_root = @vec_assign_root
        @vec_assign_root = false
        l_code, l_t = expr(node["l"], scope)
        r_code, r_t = expr(node["r"], scope)
        @vec_assign_root = saved_root
        # The oracle's compile pipeline folds scalar float arithmetic of two
        # LITERAL operands to an f32 compile-time constant (GLSL const-float
        # semantics): `x * (1.0/289.0)` bakes 0.0034602077212184668 into the
        # kernel source. Ruby's runtime rt.binary('/') would compute the raw
        # f64 quotient (0.0034602076124567475) — a different double — and
        # f32-rounding the PRODUCT afterwards does not recover the folded
        # constant (208 * f32(1/289) != f32(208 * f64(1/289)); crt mod289 /
        # simplex scanline noise, 1-ulp everywhere). Fold literal/literal
        # float ops at codegen time, f32-rounded.
        if base_unknown_fold_candidate?(op, l_code, r_code)
          lv = literal_float_of(l_code)
          rv = literal_float_of(r_code)
          if lv && rv
            v = FOLD_OPS[op].call(lv, rv)
            return ["rt.f(#{Codegen._fmt_num([v].pack("e").unpack1("e"))})", FLOAT]
          end
        end
        if COMPARE_LOGIC_OPS[op]
          return ["(#{_bool(l_code)} && #{_bool(r_code)} ? 1 : 0)", BOOL] if op == "&&"
          return ["(#{_bool(l_code)} || #{_bool(r_code)} ? 1 : 0)", BOOL] if op == "||"

          return ["rt.binary(#{Codegen.rq(op)}, #{l_code}, #{r_code})", BOOL]
        end
        if op == "*" && (l_t["mat"] || r_t["mat"]) && Codegen.width_of(l_t) > 1 && Codegen.width_of(r_t) > 1
          dim = l_t["mat"] || r_t["mat"]
          both = l_t["mat"] && r_t["mat"]
          t = both ? { "base" => "float", "width" => dim * dim, "mat" => dim } : { "base" => "float", "width" => dim }
          return ["rt.matrix_mult(#{l_code}, #{r_code}, #{dim})", t]
        end
        width = [Codegen.width_of(l_t), Codegen.width_of(r_t)].max
        lb = Codegen.base_of(l_t)
        rb = Codegen.base_of(r_t)
        base =
          if lb == "uint" || rb == "uint"
            "uint"
          elsif (lb == "int" && rb == "int") || INT_FORCING_OPS[op]
            "int"
          else
            "float"
          end
        # Whole-vector reassignment decomposes in the oracle to a JS comma-
        # assign of RAW scalar-slot expressions, where a scalar OP a vector
        # CALL-result coerces the Float32Array via toString and NaNs for
        # length>1 (cubes: `p[0] - s * (round(vec3))` -> NaN). The same
        # source shape inside a NEW-var declaration compiles to the vec3
        # helpers / .map chains (elementwise, no coercion -- shapes'
        # `vec3.multiply([], b, cos(vec))`). The discriminator is the
        # ASSIGNMENT CONTEXT, which _e_assign marks via @in_vec_assign.
        # Whole-vector assigns lower per-component too, but a DIRECT
        # scalar-op-call rhs (curl's `color = 1.0 - abs(curl)`) compiles as
        # an elementwise map-chain (`abs(p).map(_ => 1 - _)`, no coercion);
        # only a NESTED scalar-op-call deeper in the expression (cubes'
        # `p = p - s * round(p/s)`) keeps the raw string-coercion NaN.
        nested = !was_root
        if @in_vec_assign && (!@in_vec_whole_assign || nested) && base == "float" &&
           %w[* / + -].include?(op) &&
           Codegen.width_of(l_t) == 1 && width > 1 &&
           r_code.match?(/\Art\.(component_wise|unary|normalize|cross|reflect|refract|pcg3d|matrix_mult|array_index|texture)\b|\Art\.[a-z_0-9]+__\w+\.call\b/)
          return ["rt.scalar_vec_coerce(#{Codegen.rq(op)}, #{l_code}, #{r_code}, #{width})", { "base" => "float", "width" => width }]
        end
        # A whole-assign rhs that mixes scalar-op-call subtrees elementwise
        # (simplex `h = 1.0 - abs(x) - abs(y)` lowers to
        # vec4.subtract(abs(x).map(_ => 1 - _), abs(y))): the map fn stays
        # RAW (no per-element f32) and only the vec4 store rounds once.
        if @in_vec_whole_assign && was_root && base == "float" && width > 1 &&
           %w[* / + -].include?(op) && Codegen.width_of(l_t) == width &&
           Codegen.width_of(r_t) == width && _raw_elem_shape?(node)
          parts = (0...width).map do |i|
            "rt.f32(#{_raw_elem_code(node, scope, i)})"
          end
          return ["rt.construct(#{width}, #{parts.join(', ')})", { "base" => "float", "width" => width }]
        end
        ["rt.binary(#{Codegen.rq(op)}, #{l_code}, #{r_code}, #{width}, #{Codegen.rq(base)})", { "base" => base, "width" => width }]
      end

      RAW_ELEM_OPS = { "+" => "+", "-" => "-", "*" => "*", "/" => "/" }.freeze

      # True for elementwise trees of numeric literals, +-/* binaries and
      # single-argument component-wise calls (the scalar-op-call map form).
      def _raw_elem_shape?(node)
        case node["k"]
        when "num"
          true
        when "binary"
          RAW_ELEM_OPS.key?(node["op"]) && _raw_elem_shape?(node["l"]) && _raw_elem_shape?(node["r"])
        when "call"
          node["name"] == "abs" && node["args"].size == 1 && _raw_elem_shape?(node["args"][0])
        else
          false
        end
      end

      # Per-component RAW (f64) code for a raw-element-shape tree; component
      # i of a call arg is projected before the component-wise call.
      def _raw_elem_code(node, scope, i)
        case node["k"]
        when "num"
          raw = node["value"]
          f = raw.include?(".") || raw.include?("e") || raw.downcase.include?("f") ? [raw.sub(/[fF]\z/, "").to_f].pack("e").unpack1("e") : raw.to_i
          "rt.f(#{Codegen._fmt_num(f)})"
        when "binary"
          "(#{_raw_elem_code(node['l'], scope, i)}) #{RAW_ELEM_OPS[node['op']]} (#{_raw_elem_code(node['r'], scope, i)})"
        else # call abs
          a, = expr(node["args"][0], scope)
          "rt.component_wise('abs', rt.construct(1, (#{a})[#{i}]))[0]"
        end
      end

      def _e_assign(node, scope)
        op = node["op"]
        target = node["target"]
        # Reassignment of an existing width>1 id target compiles in the oracle
        # as a raw JS comma-assign of scalar-slot expressions -- inner scalar
        # OP vector-call arithmetic runs raw (see _e_binary's NaN coercion).
        # Mark the rhs evaluation so _e_binary can apply the raw semantics.
        saved_vec_assign = @in_vec_assign
        saved_vec_whole = @in_vec_whole_assign
        saved_vec_root = @vec_assign_root
        @in_vec_assign = true
        tcode0, tt0 = target["k"] == "id" ? expr(target, scope) : [nil, nil]
        @in_vec_whole_assign = !tt0.nil? && Codegen.width_of(tt0) > 1
        @vec_assign_root = true
        v_code, v_t = expr(node["value"], scope)
        @in_vec_assign = saved_vec_assign
        @in_vec_whole_assign = saved_vec_whole
        @vec_assign_root = saved_vec_root
        base_op = op == "=" ? nil : op[0..-2]
        if target["k"] == "index"
          # Array-element stores stay a direct lvalue index (JS element
          # assignment); only READS go through rt.array_index.
          obj_code, obj_t = expr(target["obj"], scope)
          idx_code, = expr(target["idx"], scope)
          tt = { "base" => Codegen.base_of(obj_t), "width" => obj_t["width"], "array" => 1 }
          rhs =
            if base_op
              b = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
              "rt.binary(#{Codegen.rq(base_op)}, #{obj_code}[(#{idx_code}).to_i], #{v_code}, #{Codegen.width_of(tt)}, #{Codegen.rq(b)})"
            else
              v_code
            end
          return ["#{obj_code}[(#{idx_code}).to_i] = #{rhs}", tt]
        end
        tcode, tt = expr(target, scope)
        if target["k"] == "id" || target["k"] == "index"
          rhs =
            if base_op
              b = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
              "rt.binary(#{Codegen.rq(base_op)}, #{tcode}, #{v_code}, #{Codegen.width_of(tt)}, #{Codegen.rq(b)})"
            else
              v_code
            end
          if target["k"] == "id" && Codegen.width_of(tt) > 1
            # In-place vector reassignment preserves JS pooled-array aliasing
            # (see the file header comment) -- Ruby's Array#replace mutates
            # the SAME array object in place, exactly like Perl's
            # `@{$tcode} = @{rhs}`. Float stores snap each element to f32;
            # int/uint vectors store exact.
            if Codegen.base_of(tt) == "int" || Codegen.base_of(tt) == "uint"
              return ["#{tcode}.replace(#{rhs})", tt]
            end
            if (seq = Codegen._sequential_assign(tcode, rhs))
              return [seq, tt]
            end
            # Mat*vec (and mat*mat) assignment: the oracle compiles the whole-
            # vector store as a component-sequential comma-assign over the
            # product expression, so an ALIASED source (rotatedCentered =
            # centered, then rotatedCentered = mat * centered) reads the
            # ALREADY-STORED earlier components (gradient's 1-ULP rc[1] drift).
            # matrix_mult_assign stores component-by-component with exactly
            # that visibility; for the non-aliased case it reduces to the
            # same f32-per-component result as matrix_mult.
            if (mm = /\Art\.matrix_mult\((.*), (.*), (\d+)\)\z/m.match(rhs))
              return ["rt.matrix_mult_assign(#{tcode}, #{mm[1]}, #{mm[2]}, #{mm[3]})", tt]
            end
            # Compound vector op-assign (`p -= 2.0*max(dot(k1,p),0)*k1`,
            # shapeMask's sdfStar5): the oracle decomposes to
            # `p[0] -= <comp0>, p[1] -= <comp1>` where each component's rhs
            # is a RAW SCALAR-slot expression re-evaluated against the
            # CURRENT p (p[1]'s dot(k1, p) sees the new p[0]). Emit
            # component-wise scalar projections re-evaluated per store; the
            # scalar binary path keeps raw f64 arithmetic with a single f32
            # round at the store, exactly like the compiled kernel.
            if base_op && Codegen.base_of(tt) == "float"
              # `p += <scalar expr>` (craquelure hash22 `p3 += dot(p3, v)`):
              # the oracle rewrites the compound store as
              # `p3 = new PooledFloat32Array([p3[0] + d, p3[1] + d, p3[2] + d])`
              # — the JS array literal evaluates d ONCE against the
              # pre-assignment p3 (mutation happens only at the assignment's
              # end), then adds the SAME d to every element. Evaluating the
              # rhs per component would feed dot() an already-mutated p3
              # (376.5 vs 11.18) and corrupt every hash. Hoist scalar rhs;
              # a width>1 rhs keeps the per-component re-evaluation below
              # (shapes3d's `p -= 2*max(dot(k1,p),0)*k1` — a genuine
              # comma-assign where later slots see earlier stores).
              if Codegen.width_of(v_t) == 1
                hv = _local("__sc#{node.object_id.abs % 100_000}")
                stores = "#{hv} = #{v_code}; " +
                         (0...Codegen.width_of(tt)).map do |i|
                           b2 = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
                           "#{tcode}[#{i}] = rt.f32(rt.binary(#{Codegen.rq(base_op)}, #{tcode}[#{i}], #{hv}, 1, #{Codegen.rq(b2)}))"
                         end.join("; ")
                return [stores, tt]
              end
              stores = (0...Codegen.width_of(tt)).map do |i|
                cc, cc_t = _vec_comp(node["value"], scope, i)
                [cc, cc_t]
              end
              # The oracle hoists a side-effecting rhs (a runtime call, e.g.
              # dla's `stepDir += randomDirection(seed)*0.3` compiles to
              # `(randomDirection(seed), [seed]=__out__, __ret__).reduce(
              # (res,el,i)=>(res[i]+=el,res), stepDir)`) EXACTLY ONCE, then
              # does the per-element in-place op against the frozen result.
              # Re-invoking the call per component would advance the callee's
              # RNG/out-param chain once per component (dla walkers: rd2
              # consumed twice, seed 0.5534 vs 0.1607). Only re-evaluate per
              # component when a projection actually references the target
              # (shapeMask's `p -= 2*max(dot(k1,p),0)*k1`: later slots see
              # earlier stores) or stays a raw scalar with no call.
              calls = stores.any? { |cc, _| cc.match?(/\bcall\(|\(begin |\b_A?[0-9a-f_]+\.call\b/) || cc.match?(/rt\.(?!binary\b|f\b|i\b|swizzle\b|construct\b|f32\b)/) }
              refs_target = stores.any? { |cc, _| cc.match?(/\b#{Regexp.escape(tcode)}\b/) }
              full, full_t = expr(node["value"], scope)
              if calls && !refs_target && Codegen.base_of(full_t) == "float" &&
                 Codegen.width_of(full_t) == Codegen.width_of(tt)
                h = _local("__hoist#{node.object_id.abs % 100_000}")
                joined = stores.each_with_index.map do |(cc, _), i|
                  b = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
                  "#{tcode}[#{i}] = rt.f32(rt.binary(#{Codegen.rq(base_op)}, #{tcode}[#{i}], #{h}[#{i}], 1, #{Codegen.rq(b)}))"
                end.join("; ")
                return ["#{h} = #{full}; #{joined}", tt]
              end
              stores = stores.each_with_index.map do |(cc, cc_t), i|
                b = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
                if Codegen.width_of(cc_t) > 1
                  # The oracle hoists runtime-call results (clamp(p,-s,s) in
                  # shapes3d) ONCE against the pre-assignment p, then does the
                  # per-element in-place subtract against that frozen result --
                  # never a raw scalar-OP-vector coercion (shapes3d SHAPE_B==10:
                  # `clamp(p,-s,s).reduce((res,el,i)=>(res[i] -= el, res), p)`).
                  # Evaluate the whole rhs once into a temp, index it per store.
                  h = _local("__hoist#{i}")
                  "#{h} = #{cc}; #{tcode}[#{i}] = rt.f32(rt.binary(#{Codegen.rq(base_op)}, #{tcode}[#{i}], #{h}[#{i}], 1, #{Codegen.rq(b)}))"
                else
                  "#{tcode}[#{i}] = rt.f32(rt.binary(#{Codegen.rq(base_op)}, #{tcode}[#{i}], #{cc}, 1, #{Codegen.rq(b)}))"
                end
              end.join("; ")
              return [stores, tt]
            end
            # Plain `=` whose rhs references the target itself (but is not a
            # call result -- the oracle hoists call results once, see
            # rotate2D(p, rad).reduce in shapeMask and mod289_2(i).reduce in
            # kaleido; the out-param call form "(begin _retc, ... = x.call(...);
            # _retc end)" is likewise a hoisted call result): the compiled
            # comma-assign re-inlines the rhs text per component, so a later
            # component reads already-stored ones.
            if base_op.nil? && Codegen.base_of(tt) == "float" &&
               rhs.match?(/\b#{Regexp.escape(tcode)}\b/) &&
               !rhs.match?(/\Art\.[a-z_0-9]+__\w+\.call\b|\Art\.texture\b|\bcall\(|\(begin /)
              # JS evaluates the whole array literal against the OLD target
              # (cpu_vector_assignment_N), then stores element-wise — a slot
              # referencing the target must see pre-assignment values
              # (polygon's `st = vec2(st.y, -st.x)` swap: sequential stores
              # make st[1] = -new_st[0]). If any projected slot still reads
              # the target, fall back to the once-eval replace below.
              slots_ref = (0...Codegen.width_of(tt)).any? do |i|
                cc, = _vec_comp(node["value"], scope, i)
                cc.match?(/\b#{Regexp.escape(tcode)}\b/)
              end
              unless slots_ref
              stores = (0...Codegen.width_of(tt)).map do |i|
                cc, = _vec_comp(node["value"], scope, i)
                # A projection that stays a whole vector or still contains a
                # runtime CALL (the oracle hoists every call result once --
                # fract(st).reduce(...) in kaleido -- rather than re-invoking
                # per component) cannot feed a per-component raw store; fall
                # back to the generic once-eval form.
                if cc.match?(/\bcall\(/) || cc.match?(/\Art\.(?!binary\b|f\b|i\b|swizzle\b|construct\b)/) || cc.start_with?("(begin ")
                  return ["#{tcode}.replace((#{rhs}).map { |c| rt.f32(c) })", tt]
                end

                "#{tcode}[#{i}] = rt.f32(#{cc})"
              end.join("; ")
              return [stores, tt]
              end
            end
            # Generic whole-vector rhs: the oracle evaluates the rhs ONCE
            # (the emitted expression reads the rhs's own operands, which are
            # distinct pooled arrays from the target in every observed
            # kernel), so a plain in-place replace of f32-snapped components
            # is exact. Components that the transpiler already applied
            # f32-rounding to via rt.f32 inside the rhs are not double-
            # rounded (f32 is idempotent).
            return ["#{tcode}.replace((#{rhs}).map { |c| rt.f32(c) })", tt]
          end
        end
        if target["k"] == "id"
          # Scalar (width==1) identifier assignment: plain rebinding, like
          # JS. Note width>1 id targets ALWAYS returned above, so reaching
          # here means width 1.
          return ["#{tcode} = #{rhs}", tt]
        end
        if target["k"] == "member"
          obj_code, obj_t = expr(target["obj"], scope)
          if Codegen.base_of(obj_t) == "struct"
            fields = @structs[obj_t["struct"]] || []
            idx = 0
            fields.each_index do |i|
              if fields[i][1] == target["field"]
                idx = i
                break
              end
            end
            target_code = "#{obj_code}[#{idx}]"
            rhs = if base_op
                    b = Codegen.base_of(tt) == "uint" ? "uint" : (Codegen.base_of(tt) == "int" ? "int" : "float")
                    "rt.binary(#{Codegen.rq(base_op)}, #{target_code}, #{v_code}, #{Codegen.width_of(tt)}, #{Codegen.rq(b)})"
                  else
                    v_code
                  end
            if Codegen.width_of(tt) > 1
              if Codegen.base_of(tt) == "int" || Codegen.base_of(tt) == "uint"
                return ["#{target_code}.replace(#{rhs})", tt]
              end
              return ["#{target_code}.replace((#{rhs}).map { |c| rt.f32(c) })", tt]
            end
            return ["#{target_code} = #{rhs}", tt]
          end
          sw = target["field"]
          rhs =
            if base_op
              cur = "rt.swizzle(#{obj_code}, #{Codegen.rq(sw)})"
              ob = Codegen.base_of(obj_t)
              b = ob == "uint" ? "uint" : (ob == "int" ? "int" : "float")
              "rt.binary(#{Codegen.rq(base_op)}, #{cur}, #{v_code}, #{sw.length}, #{Codegen.rq(b)})"
            else
              v_code
            end
          return [
            "#{obj_code} = rt.assign_swizzle(#{obj_code}, #{Codegen.rq(sw)}, #{rhs})",
            { "base" => Codegen.base_of(obj_t), "width" => sw.length },
          ]
        end
        raise "codegen: bad assignment target #{target["k"]}\n"
      end

      # Scalar projection of a float-vector expression for the oracle's
      # comma-assign decomposition (`p[1] -= (2*(max(dot(k1, p), 0)))*k1[1]`):
      # returns [code, type] for component i with every level kept SCALAR so
      # the arithmetic runs raw f64 (no intermediate vector f32 rounding),
      # matching the compiled raw scalar-slot JS. Bare vector identifiers
      # become element reads (which see the CURRENT target state when the
      # projection is the target itself -- the aliasing semantics). Call
      # results and unhandled nodes fall back to evaluating the whole vector
      # and indexing it (pure in every observed kernel).
      def _vec_comp(node, scope, i)
        k = node["k"]
        case k
        when "num", "bool"
          expr(node, scope)
        when "id"
          code, t = expr(node, scope)
          if Codegen.width_of(t) > 1
            ["#{code}[#{i}]", { "base" => Codegen.base_of(t), "width" => 1 }]
          else
            [code, t]
          end
        when "member"
          code, t = expr(node["obj"], scope)
          field = node["field"]
          if Codegen.base_of(t) == "struct"
            whole, wt = expr(node, scope)
            # The struct result of a call (voxelTrace hit) is modeled as a
            # flat array; `hit.dist` is `hit[0]` — the MEMBER's own value.
            # Indexing it again wraps a float scalar and crashes.
            return ["(#{whole})[#{i}]", { "base" => "float", "width" => 1 }] unless whole.match?(/[A-Za-z0-9_)\]]\[\d+\]\z/)

            return [whole, wt]
          end
          if field.length > 1
            ["rt.swizzle(#{code}, #{Codegen.rq(field[i])})", { "base" => Codegen.base_of(t), "width" => 1 }]
          else
            ["rt.swizzle(#{code}, #{Codegen.rq(field)})", { "base" => Codegen.base_of(t), "width" => 1 }]
          end
        when "unary"
          code, t = expr(node["x"], scope)
          if Codegen.width_of(t) > 1
            ["rt.unary(#{Codegen.rq(node["op"])}, #{code}[#{i}])", { "base" => Codegen.base_of(t), "width" => 1 }]
          else
            ["rt.unary(#{Codegen.rq(node["op"])}, #{code})", t]
          end
        when "binary"
          op = node["op"]
          # A matrix operand cannot be projected to a scalar slot: the flat
          # pooled layout of a mat3 has no meaningful single element for
          # component i, and the oracle keeps the whole matrix product
          # (shapes3d's `lms = invB * c` compiled to a hoisted
          # matrix_mult(lms slots) — NOT per-component invB[0]*c[0]).
          # Fall back to whole-expression evaluation indexed per component.
          wl, wr = expr(node["l"], scope)[1], expr(node["r"], scope)[1]
          if wl["mat"] || wr["mat"]
            whole, wt = expr(node, scope)
            return ["(#{whole})[#{i}]", { "base" => Codegen.base_of(wt), "width" => 1 }]
          end
          l_code, l_t = _vec_comp(node["l"], scope, i)
          r_code, r_t = _vec_comp(node["r"], scope, i)
          # A projected operand may still be WHOLE-VECTOR (routed calls
          # like pcg3d return their full code); indexing it raw would
          # divide an IVec object. Index the whole value per component
          # instead (re-evaluating a deterministic call per slot is
          # value-identical).
          l_code, l_t = ["(#{l_code})[#{i}]", { "base" => Codegen.base_of(l_t), "width" => 1 }] if Codegen.width_of(l_t) > 1
          r_code, r_t = ["(#{r_code})[#{i}]", { "base" => Codegen.base_of(r_t), "width" => 1 }] if Codegen.width_of(r_t) > 1
          # folds const float arithmetic to an f32 literal. Without this,
          # raw scalar slots multiply by the f64 quotient (mod289's
          # 1.0/289.0 → 0.653979238754 vs the oracle's folded-constant
          # product 0.653979241848).
          if Codegen.base_of(l_t) == "float" && Codegen.base_of(r_t) == "float" &&
             %w[* / + -].include?(op)
            lv = literal_float_of(l_code)
            rv = literal_float_of(r_code)
            if lv && rv
              v = FOLD_OPS[op].call(lv, rv)
              return ["rt.f(#{Codegen._fmt_num([v].pack("e").unpack1("e"))})", { "base" => "float", "width" => 1 }]
            end
          end
          if COMPARE_LOGIC_OPS[op]
            return ["(#{_bool(l_code)} && #{_bool(r_code)} ? 1 : 0)", BOOL] if op == "&&"
            return ["(#{_bool(l_code)} || #{_bool(r_code)} ? 1 : 0)", BOOL] if op == "||"

            return ["rt.binary(#{Codegen.rq(op)}, #{l_code}, #{r_code})", BOOL]
          end
          width = 1
          lb = Codegen.base_of(l_t)
          rb = Codegen.base_of(r_t)
          base =
            if lb == "uint" || rb == "uint"
              "uint"
            elsif (lb == "int" && rb == "int") || INT_FORCING_OPS[op]
              "int"
            else
              "float"
            end
          # Scalar-OP-vector-call inside the comma-assign projection keeps the
          # oracle's raw JS operator semantics: NaN (see _e_binary's note).
          if base == "float" && %w[* / + -].include?(op) &&
             (l_t["callvec"] || r_t["callvec"])
            return ["rt.scalar_vec_coerce(#{Codegen.rq(op)}, #{l_code}, #{r_code}, 1)", { "base" => "float", "width" => 1 }]
          end
          if base == "float" && %w[* / + -].include?(op)
            # The oracle's per-component comma-assign arithmetic is RAW JS:
            # f64 adds/muls/divides over the pooled f32 reads with a SINGLE
            # f32 round at the element store. rt.binary rounds every
            # intermediate to f32 (bitEffects bitMask:
            # `st[0] -= (0.5*fullResolution[0])/fullResolution[1]` needs the
            # raw form to match), so emit raw operators here.
            return ["((#{l_code}) #{op} (#{r_code}))", { "base" => "float", "width" => 1 }]
          end
          ["rt.binary(#{Codegen.rq(op)}, #{l_code}, #{r_code}, #{width}, #{Codegen.rq(base)})", { "base" => base, "width" => 1 }]
        when "cond"
          c_code, = expr(node["c"], scope)
          a_code, a_t = _vec_comp(node["a"], scope, i)
          b_code, b_t = _vec_comp(node["b"], scope, i)
          # A whole-vector branch (callvec: normalize(pcg3d(...)) etc.)
          # must be INDEXED per component — returning the vector code as a
          # scalar slot feeds an Array into rt.f32 (heightmap3d's
          # `normal[k] = dot > 0 ? normalize(normal)[k] : c[k]`).
          a_code, a_t = ["(#{a_code})[#{i}]", { "base" => Codegen.base_of(a_t), "width" => 1 }] if Codegen.width_of(a_t) > 1
          b_code, = ["(#{b_code})[#{i}]"] if Codegen.width_of(b_t) > 1
          ["(#{_bool(c_code)} ? (#{a_code}) : (#{b_code}))", a_t]
        when "construct"
          code, t = expr(node, scope)
          w = Codegen.width_of(t)
          if w == 1
            # rt.construct(1, x) is a 1-element pooled ARRAY; projected to a
            # scalar slot it must become the bare element (bitEffects:
            # `st[0] += vec1(seed)[0] + 1000` -- an Array in raw scalar
            # arithmetic would raise). Only float/int/uint constructs of one
            # element appear here.
            return [code, t] unless code.start_with?("rt.construct(1,")

            inner = code.sub(/\Art\.construct\(1, /m, "").sub(/\)\z/m, "")
            return ["(#{inner})", t]
          end

          # A constructor of pure expressions is inlined component-by-component
          # in the oracle's comma-assign (st[0] - (0.5*res.x)/res.y, st[1] - 0.5)
          # -- never a raw vector operator. Flatten GLSL construct args
          # (scalars fill one slot; a vec arg fills its width) and project.
          # Slots go through _vec_comp so nested float arithmetic stays raw
          # (rt.binary would f32-round intermediates; the oracle rounds once
          # at the element store).
          flat = []
          node["args"].each do |a|
            ac, at = expr(a, scope)
            aw = Codegen.width_of(at)
            if aw > 1 && Codegen.base_of(at) == "float" && !at["mat"]
              (0...aw).each { |j| flat << ["rt.swizzle(#{ac}, #{Codegen.rq((%w[x y z w])[j])})", 1] }
            else
              flat << _vec_comp(a, scope, i)
            end
          end
          slot = flat[i] || flat[-1]
          slot_w = slot[1].is_a?(Hash) ? Codegen.width_of(slot[1]) : 1
          if slot_w > 1
            # A whole-vector element (routed calls like pcg3d) surviving in
            # the flat list: index it per component or the projected slot
            # divides an IVec (warp's prng: pcg3d(...)/4294967296).
            ["(#{slot[0]})[#{i}]", { "base" => Codegen.base_of(slot[1]), "width" => 1 }]
          else
            ["(#{slot[0]})", { "base" => "float", "width" => 1 }]
          end
        when "call"
          # A component-wise builtin call (stdlib unary/binary/ternary:
          # abs/tanh/round/clamp/...) applied to a vector is ELEMENTWISE in
          # the oracle (#unary/#binary loop per component), so the compiled
          # comma-assign decomposes the call ITSELF per component --
          # curl's rewritten `tanh(curl.x * intensity) * 0.5 + 0.5` emits
          # `(tanh(curl[0] * intensity)) * 0.5 + 0.5` (scalar Math.tanh), and
          # ridges' `1 - abs(color*2-1)` emits
          # `abs(vec).map(_ => 1 - _)` elementwise. Project the ARGS through
          # _vec_comp and re-emit the call with scalar args: rt.component_wise
          # with all-scalar args returns a scalar (the #unary scalar path),
          # keeping the arithmetic scalar and NaN-free. USER functions and
          # runtime-routed calls (pcg3d, texture, ...) are NOT elementwise
          # decomposable this way -- they keep the whole-vector callvec form
          # (scalar OP such a result IS the NaN coercion, cubes' round case).
          if !@overloads.key?(node["name"]) && !ROUTED.key?(node["name"]) && !DERIV_FUNCS[node["name"]] &&
             !TYPE.key?(node["name"]) && !node["args"].empty?
            # The oracle compiles a VECTOR builtin call as
            # fn(new PooledFloat32Array([scalar slots...])): each slot's
            # arithmetic is f32-ROUNDED at the array store BEFORE the call
            # reads it (mod289's floor(x[0]*(1/289)): f32(0.65397925931) =
            # 0.653979241848 — flooring the raw f64 instead reads the
            # unrounded double). A genuinely SCALAR call site keeps raw f64
            # (Math.floor), so only original-width>1 float args wrap.
            projected = node["args"].map do |a|
              c, t = _vec_comp(a, scope, i)
              _, at = expr(a, scope)
              if Codegen.base_of(t) == "float" && Codegen.width_of(at) > 1 &&
                 a["k"] == "binary"
                ["rt.f32(#{c})", t]
              else
                [c, t]
              end
            end
            scalars = projected.map { |c, _| c }
            w = 1
            projected.each { |_, t| w = Codegen.width_of(t) if Codegen.width_of(t) > w }
            return ["rt.component_wise(#{Codegen.rq(node["name"])}#{scalars.empty? ? "" : ", #{scalars.join(", ")}"})", { "base" => "float", "width" => 1 }]
          end
          code, t = expr(node, scope)
          if Codegen.width_of(t) > 1
            # Sampler reads (rt.texture) return pooled f32 vectors; the oracle
            # combines them ELEMENTWISE via .map (blurH:
            # `texture(...).map(_ => _ * weight).reduce((res,el,i)=>...)`) --
            # never a raw scalar-OP-vector coercion. Project as a pure whole-
            # vec evaluation indexed per component.
            return ["(#{code})[#{i}]", { "base" => Codegen.base_of(t), "width" => 1 }] if code.start_with?("rt.texture")

            # Keep the WHOLE vector call: under the oracle's raw comma-assign a
            # scalar OP this vec-call result is a raw JS operator (NaN), so the
            # projection must not pre-index it. The binary case below turns
            # scalar/call products into the NaN coercion. (A width-1 construct
            # like vec1(seed) is a scalar and returns as-is below.)
            [code, { "base" => Codegen.base_of(t), "width" => Codegen.width_of(t), "callvec" => true }]
          else
            [code, t]
          end
        when "index"
          code, t = expr(node, scope)
          if Codegen.width_of(t) > 1
            return ["(#{code})[#{i}]", { "base" => Codegen.base_of(t), "width" => 1 }] if code.start_with?("rt.texture")

            # An INDEX of an already-indexed scalar member (hit[0] is the
            # float dist member of voxelTrace's [dist, normal, voxel]
            # result; ro[0], hit[0] etc.) is NOT a whole vector — wrapping
            # it in another (...)[i] indexes the FLOAT and crashes
            # (render3d's FILTERING==1 branch: `(hit[0])[0]`).
            return [code, t] if code.match?(/\)\[\d+\]\z|[A-Za-z_][A-Za-z0-9_]*\[\d+\]\z/)

            [code, { "base" => Codegen.base_of(t), "width" => Codegen.width_of(t), "callvec" => true }]
          else
            [code, t]
          end
        else
          whole, wt = expr(node, scope)
          return [whole, wt] if Codegen.width_of(wt) == 1
          # Member/index extractions of a callvec result are the MEMBER's
          # own type, not the whole vector — don't index a scalar float
          # (render3d voxelTrace hit.dist → `(hit[0])[i]` crash).
          return [whole, wt] if whole.match?(/\)\[\d+\]\z|[A-Za-z_][A-Za-z0-9_]*\[\d+\]\z/)

          ["(#{whole})[#{i}]", { "base" => Codegen.base_of(wt), "width" => 1 }]
        end
      end

      def _e_construct(node, scope)
        tname = node["type"]
        args = node["args"].map { |a| expr(a, scope) }
        elems = args.map { |a| a[0] }.join(", ")
        unless node["array"].nil? # array constructor TYPE[N](...)
          elt = TYPE[tname] || FLOAT
          return ["rt.array([#{elems}])", { "base" => elt["base"], "width" => elt["width"], "array" => 1 }]
        end
        if @structs[tname]
          return ["[#{elems}]", { "base" => "struct", "width" => 0, "struct" => tname }]
        end
        t = TYPE[tname]
        unless t
          w = 1
          args.each { |a| w = Codegen.width_of(a[1]) if Codegen.width_of(a[1]) > w }
          t = { "base" => "float", "width" => w }
        end
        # float(<uint scalar>) parses as a float CONSTRUCT of a uint value: a
        # uint-to-float VALUE conversion, so f32 rounds 4294967295 up to
        # 4294967296.0 (bitEffects/cellNoise/cell/noise hash denominators; the
        # oracle emits cpu_float(4294967296) for every
        # float(uint(0xffffffff))/float(0xffffffffu) spelling -- 79 occurrences,
        # never 4294967295). A bare rt.i(...) would keep the pre-rounding
        # integer. Covers BOTH the literal form (args[0].k == "num" with a
        # uint literal) and the uint(0xffffffff) call form (a width-1 uint
        # construct / cast of a uint literal).
        if args.length == 1 && t["base"] == "float" && t["width"] == 1 &&
           Codegen.base_of(args[0][1]) == "uint" && Codegen.width_of(args[0][1]) == 1
          arg = node["args"][0]
          # String#match? does NOT set Regexp.last_match -- use .match.
          m = (arg["k"] || "") == "num" ? nil : /\Art\.construct\(1, rt\.i\((\d+)\)(?:, '(?:int|uint)')?\)/.match(args[0][0])
          raw =
            if (arg["k"] || "") == "num"
              arg["value"].to_s.sub(/[uU]\z/, "")
            elsif m
              m[1]
            end
          unless raw
            return ["rt.construct(#{t["width"]}#{elems == "" ? "" : ", #{elems}"}#{Codegen._construct_base(t)})", t]
          end

          v = raw =~ /\A0[xX]/ ? raw.to_i(16) : raw.to_i
          # f32 round-trip: 4294967295 -> 4294967296.0 (JS Math.fround),
          # matching the oracle's cpu_float(4294967296) emission.
          f32 = [v.to_f].pack("e").unpack1("e")
          return ["rt.f(#{Codegen._fmt_num(f32)})", FLOAT]
        end
        if Codegen.base_of(t) == "int" || Codegen.base_of(t) == "uint"
          elems = args.map do |code, arg_t|
            if Codegen.base_of(arg_t) == "float" && Codegen.width_of(arg_t) > 1
              "rt.construct(#{Codegen.width_of(arg_t)}, #{code})"
            else
              code
            end
          end.join(", ")
        end
        ["rt.construct(#{t["width"]}#{elems == "" ? "" : ", #{elems}"}#{Codegen._construct_base(t)})", t]
      end

      DERIV_FUNCS = %w[dFdx dFdy fwidth].each_with_object({}) { |n, h| h[n] = true }.freeze

      ROUTED = {
        "texture" => ->(_g, c, _a) { ["rt.texture(#{c[0]}, #{c[1]})", VEC4] },
        "textureLod" => ->(_g, c, _a) { ["rt.texture(#{c[0]}, #{c[1]})", VEC4] },
        "texelFetch" => ->(_g, c, _a) { ["rt.texel_fetch(#{c[0]}, #{c[1]}, #{c.length > 2 ? c[2] : "0"})", VEC4] },
        "textureSize" => ->(_g, c, _a) { ["rt.texture_size(#{c[0]})", TYPE["ivec2"]] },
        "length" => ->(_g, c, _a) { ["rt.length(#{c[0]})", FLOAT] },
        "__array_length" => ->(_g, c, _a) { ["#{c[0]}.length", TYPE["int"]] },
        "distance" => ->(_g, c, _a) { ["rt.distance(#{c[0]}, #{c[1]})", FLOAT] },
        "dot" => ->(_g, c, _a) { ["rt.dot(#{c[0]}, #{c[1]})", FLOAT] },
        "normalize" => ->(_g, c, a) { ["rt.normalize(#{c[0]})", a[0][1]] },
        "cross" => ->(_g, c, a) { ["rt.cross(#{c[0]}, #{c[1]})", a[0][1]] },
        "reflect" => ->(_g, c, a) { ["rt.reflect(#{c[0]}, #{c[1]})", a[0][1]] },
        "refract" => ->(_g, c, a) { ["rt.refract(#{c[0]}, #{c[1]}, #{c[2]})", a[0][1]] },
        "pcg3d" => ->(_g, c, _a) { ["rt.pcg3d(#{c[0]})", TYPE["uvec3"]] },
        "cpu_cell3d_hash_result" => ->(_g, c, _a) { ["rt.cpu_cell3d_hash_result(#{c[0]})", TYPE["vec3"]] },
        "cpu_noise3d_hash4" => ->(_g, c, _a) { ["rt.cpu_noise3d_hash4(#{c[0]}, #{c[1]})", FLOAT] },
        "cpu_umul" => ->(_g, c, _a) { ["rt.binary('*', #{c[0]}, #{c[1]}, 1, 'uint')", TYPE["uint"]] },
        "hashUint" => ->(_g, c, _a) { ["rt.hash_uint(#{c[0]})", TYPE["uint"]] },
        "hash_uint" => ->(_g, c, _a) { ["rt.hash_uint(#{c[0]})", TYPE["uint"]] },
        "floatBitsToUint" => ->(_g, c, _a) { ["rt.float_bits_to_uint(#{c[0]})", TYPE["uint"]] },
        "uintBitsToFloat" => ->(_g, c, _a) { ["rt.uint_bits_to_float(#{c[0]})", FLOAT] },
        "packHalf2x16" => ->(_g, c, _a) { ["rt.pack_half_2x16(#{c[0]})", TYPE["uint"]] },
        "unpackHalf2x16" => ->(_g, c, _a) { ["rt.unpack_half_2x16(#{c[0]})", TYPE["vec2"]] },
        "cpu_float" => ->(_g, c, _a) { ["rt.construct(1, #{c[0]})", FLOAT] },
        "cpu_ivec2" => ->(_g, c, _a) { ["rt.construct(2, #{c.join(", ")}, 'int')", TYPE["ivec2"]] },
        "cpu_ivec3" => ->(_g, c, _a) { ["rt.construct(3, #{c.join(", ")}, 'int')", TYPE["ivec3"]] },
        "cpu_uvec2" => ->(_g, c, _a) { ["rt.construct(2, #{c.join(", ")}, 'uint')", TYPE["uvec2"]] },
        "cpu_uvec3" => ->(_g, c, _a) { ["rt.construct(3, #{c.join(", ")}, 'uint')", TYPE["uvec3"]] },
      }.freeze

      def _e_call(node, scope)
        name = node["name"]
        args = node["args"].map { |a| expr(a, scope) }
        codes = args.map { |a| a[0] }
        if DERIV_FUNCS[name]
          @uses_deriv = true
          return ["rt.#{name}(#{codes[0]})", args[0][1]]
        end
        r = ROUTED[name]
        # cpu_float(0xffffffffu): the hash-boundary rewrite turns
        # `float(0xffffffffu)` into cpu_float(<uint literal>); the value is a
        # uint-to-float VALUE conversion, so f32 rounds 4294967295 up to
        # 4294967296.0 (bitEffects/cellNoise hash denominators). Emit the
        # rounded float literal, not the raw integer.
        if name == "cpu_float" && args.length == 1 &&
           Codegen.base_of(args[0][1]) == "uint" && Codegen.width_of(args[0][1]) == 1
          mcf = (node["args"][0]["k"] || "") == "num" ? nil : /\Art\.construct\(1, rt\.i\((\d+)\)(?:, '(?:int|uint)')?\)/.match(codes[0])
          raw =
            if (node["args"][0]["k"] || "") == "num"
              node["args"][0]["value"].to_s.sub(/[uU]\z/, "")
            elsif mcf
              mcf[1]
            end
          if raw
            v = raw =~ /\A0[xX]/ ? raw.to_i(16) : raw.to_i
            f32 = [v.to_f].pack("e").unpack1("e")
            return ["rt.f(#{Codegen._fmt_num(f32)})", FLOAT]
          end
        end
        return r.call(self, codes, args) if r

        # A user-defined `uvec3 pcg(uvec3)` is the PCG3D hash: the oracle's
        # compiler recognizes the body and emits stdlib.pcg3d for every call
        # (all 35 `function pcg` sites in the compiled kernels are
        # `return $runtime.stdlib.pcg3d(value);`). stdlib.pcg3d wraps each
        # op mod 2^32 (Math.imul); inlining the GLSL body as raw uint
        # rt.binary ops would keep unwrapped f64 products and corrupt every
        # hash (cellNoise/cell/noise/bitEffects prng).
        if name == "pcg" && args.length == 1 &&
           Codegen.base_of(args[0][1]) == "uint" && Codegen.width_of(args[0][1]) == 3
          return ["rt.pcg3d(#{codes[0]})", TYPE["uvec3"]]
        end

        if @overloads[name]
          fn = _resolve_overload(name, args.map { |a| a[1] })
          # A vecN(...) argument of a USER function call: the oracle compiles
          # it as fn(new PooledFloat32Array([raw scalar slots...])) — each
          # slot's arithmetic is RAW f64 JS with ONE f32 at the pooled store
          # (noise3d's snoise(new PF32A([p[0]*scaleN + seed, ...])): the
          # intermediate p[0]*scaleN stays unrounded). Emitting the slots as
          # vector rt.binary ops f32-rounds every intermediate (two rounds —
          # the 1-ulp noise3d time-0 divergence). Project the slots through
          # _vec_comp exactly like the decl path (same filter: float width>1,
          # non-id, non-construct init) and keep ONE f32 at the construct
          # store. Literal/id/call-result components are already f32-stored
          # pooled values and are unaffected.
          codes = codes.each_with_index.map do |c, ai|
            a = node["args"][ai]
            a_t = args[ai][1]
            next c unless ((a["k"] || "") == "construct" || a["k"] == "binary") &&
                          Codegen.base_of(a_t) == "float" && Codegen.width_of(a_t) > 1 && !a_t["mat"]
            slots = (0...Codegen.width_of(a_t)).map { |ci| _vec_comp(a, scope, ci) }
            "rt.construct(#{Codegen.width_of(a_t)}, #{slots.map(&:first).join(", ")})"
          end
          out_idxs = fn["out_idxs"] || []
          unless out_idxs.empty?
            targets = out_idxs.map { |i| expr(node["args"][i], scope)[0] }
            call = "#{fn["mangled"]}.call(#{codes.join(", ")})"
            return ["(begin _retc, #{targets.join(", ")} = #{call}; _retc end)", fn["ret"]]
          end
          return ["#{fn["mangled"]}.call(#{codes.join(", ")})", fn["ret"]]
        end
        if TYPE[name] # scalar cast: int(x), float(x), uint(x)
          t = TYPE[name]
          # float(<uint scalar>): a uint-to-float VALUE conversion -- f32
          # rounds 4294967295 up to 4294967296.0 (the port contract's
          # `float(0xffffffff) -> 4294967296.0` row; the oracle emits
          # cpu_float(4294967296) for EVERY spelling -- 79 occurrences in the
          # compiled kernels, never 4294967295). Covers BOTH the literal form
          # (`float(0xffffffffu)`) and the `float(uint(0xffffffff))` call
          # form (cellNoise/cell/noise prng denominators): the inner uint
          # cast is a width-1 uint-typed construct/call of a uint literal,
          # whose emitted code embeds the integer via rt.i(N). A bare
          # rt.i(4294967295) would keep the pre-rounding integer and skew
          # every hash denominator by 1 ULP.
          if name == "float" && args.length == 1 &&
             Codegen.base_of(args[0][1]) == "uint" && Codegen.width_of(args[0][1]) == 1
            mcast = (node["args"][0]["k"] || "") == "num" ? nil : /\Art\.construct\(1, rt\.i\((\d+)\)(?:, '(?:int|uint)')?\)/.match(codes[0])
            raw =
              if (node["args"][0]["k"] || "") == "num"
                node["args"][0]["value"].to_s.sub(/[uU]\z/, "")
              elsif mcast
                mcast[1]
              end
            if raw
              v = raw =~ /\A0[xX]/ ? raw.to_i(16) : raw.to_i
              f32 = [v.to_f].pack("e").unpack1("e")
              return ["rt.f(#{Codegen._fmt_num(f32)})", FLOAT]
            end
          end
          return ["rt.construct(#{t["width"]}#{codes.empty? ? "" : ", #{codes.join(", ")}"}#{Codegen._construct_base(t)})", t]
        end
        # component-wise builtin
        width = 1
        args.each { |a| width = Codegen.width_of(a[1]) if Codegen.width_of(a[1]) > width }
        # The oracle compiles `floor(<vec arithmetic>)` as
        # floor(new PooledFloat32Array([raw scalar slots...])): each slot's
        # arithmetic is RAW f64 JS with a SINGLE f32 round at the array
        # store (crt simplex: floor(p * ns.z * ns.z) slots
        # (p[0]*ns[2])*ns[2] — the intermediate p[0]*ns[2] = 40.0000017881
        # stays unrounded). Routing the argument through rt.binary vector
        # ops f32-rounds every intermediate (fround(fround(280*n)*n) =
        # 5.71428585052 vs the oracle's 5.71428632736 — 1 ulp, amplified by
        # every downstream gradient). Project vector ARITHMETIC args
        # per-component through _vec_comp (raw operators, one round at
        # construct); id/swizzle/call-result args are already f32-stored
        # pooled values and keep the whole-vector form.
        codes = codes.each_with_index.map do |c, ai|
          a_t = args[ai][1]
          if Codegen.base_of(a_t) == "float" && Codegen.width_of(a_t) > 1 &&
             node["args"][ai]["k"] == "binary"
            slots = (0...Codegen.width_of(a_t)).map { |ci| _vec_comp(node["args"][ai], scope, ci) }
            "rt.construct(#{Codegen.width_of(a_t)}, #{slots.map(&:first).join(", ")})"
          else
            # Scalar args stay RAW: the oracle's #unary/#binary call a
            # scalar fn directly (F32 rounds the RESULT, not the arg).
            # Wrapping in rt.f32 broke hash3's fract(sin(dot)*C) — the
            # raw f64 product must reach fract.
            c
          end
        end
        base = (!args.empty? && args.none? { |a| Codegen.base_of(a[1]) != "int" && Codegen.base_of(a[1]) != "uint" }) ? "int" : "float"
        ["rt.component_wise(#{Codegen.rq(name)}#{codes.empty? ? "" : ", #{codes.join(", ")}"})", { "base" => base, "width" => width }]
      end

      def _resolve_overload(name, argtypes)
        cands = @overloads[name]
        return cands[0] if cands.length == 1

        same = cands.select { |c| c["ptypes"].length == argtypes.length }
        same.each do |c|
          ok = true
          argtypes.each_index do |i|
            p = c["ptypes"][i]
            a = argtypes[i]
            if Codegen.base_of(p) != Codegen.base_of(a) || Codegen.width_of(p) != Codegen.width_of(a)
              ok = false
              break
            end
          end
          return c if ok
        end
        same.empty? ? cands[0] : same[0]
      end
    end
  end
end
