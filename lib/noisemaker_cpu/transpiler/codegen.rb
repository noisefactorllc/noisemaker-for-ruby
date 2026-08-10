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
        "'#{s.to_s.gsub(/(['\\])/, '\\\\\\1')}'"
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
            init_code = dc["init"].nil? ? nil : expr(dc["init"], scope)[0]
            e = scope.define(dc["name"], t)
            _local(e["py"])
            if !init_code.nil?
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
            code, = expr(val_node, scope)
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

        send(m, node, scope)
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
          return ["rt.f(#{Codegen._fmt_num(body)})", FLOAT]
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
          return ["#{obj_code}[(#{idx_code}).to_i]", { "base" => Codegen.base_of(obj_t), "width" => obj_t["width"] }]
        end
        ["#{obj_code}[(#{idx_code}).to_i]", { "base" => Codegen.base_of(obj_t), "width" => 1 }]
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

      def _e_binary(node, scope)
        op = node["op"]
        l_code, l_t = expr(node["l"], scope)
        r_code, r_t = expr(node["r"], scope)
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
        ["rt.binary(#{Codegen.rq(op)}, #{l_code}, #{r_code}, #{width}, #{Codegen.rq(base)})", { "base" => base, "width" => width }]
      end

      def _e_assign(node, scope)
        op = node["op"]
        target = node["target"]
        v_code, = expr(node["value"], scope)
        base_op = op == "=" ? nil : op[0..-2]
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
            return ["#{tcode}.replace((#{rhs}).map { |c| rt.f32(c) })", tt]
          end
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
            return ["#{obj_code}[#{idx}] = #{v_code}", tt]
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
        return r.call(self, codes, args) if r

        if @overloads[name]
          fn = _resolve_overload(name, args.map { |a| a[1] })
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
          return ["rt.construct(#{t["width"]}#{codes.empty? ? "" : ", #{codes.join(", ")}"}#{Codegen._construct_base(t)})", t]
        end
        # component-wise builtin
        width = 1
        args.each { |a| width = Codegen.width_of(a[1]) if Codegen.width_of(a[1]) > width }
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
