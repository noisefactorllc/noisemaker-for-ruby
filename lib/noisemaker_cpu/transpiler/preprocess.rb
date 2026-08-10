# frozen_string_literal: true

# GLSL preprocessing + light normalization (pure Ruby).
#
# Reproduces the parts of the reference pipeline that matter for codegen:
#   - strip #version / #extension / #pragma / #line
#   - object-like #define expansion
#   - #ifdef/#ifndef/#if/#elif/#else/#endif: static conditions are evaluated;
#     conditions on a RUNTIME define are lowered into real GLSL if/else fed by
#     a uniform of that name (or, at global scope, include-all-branches -- the
#     transpiled functions are uniquely named and dispatched at runtime)
#   - capture `out vec4 X;` -> global `vec4 X;` + record X in outputs
#   - capture `in vecN Y;` varyings (dropped; codegen maps them to ctx uv)
#
# Ruby-safety note: perl's kernels/tooling pass small control flags around as
# Integer 0/1 and rely on Perl's native `0 is false` truthiness everywhere
# (`if ($frame->{active})`, `$fr->{taken} ||= $val`, ...). Ruby's `0` is
# truthy, so every such check below is written as an explicit `== 0` / `!= 0`
# comparison instead of a bare boolean test -- this file's own version of
# Ruby trap #1, one level below the GLSL-kernel-facing rt.bool() rule that
# applies to Codegen's emitted text.

module NoisemakerCpu
  module Transpiler
    module Preprocess
      # Remove block and line comments before preprocessing (a // comment
      # trailing a #define value would otherwise be captured into the macro).
      def self._strip_comments(source)
        source = source.gsub(%r{/\*.*?\*/}m, " ")
        source.gsub(%r{//[^\n]*}, "")
      end

      def self.normalize(source, runtime_defines = nil)
        runtime_defines ||= {}
        body = _preprocess(_strip_comments(source), runtime_defines)

        out_lines = []
        output_locations = []
        varyings = []
        body.split("\n", -1).each do |line|
          if (m = /\A\s*layout\s*\(([^)]*)\)\s*out\s+(\w+)\s+(\w+)\s*;\s*\z/.match(line))
            location_match = /\blocation\s*=\s*(\d+)/.match(m[1])
            location = location_match ? location_match[1].to_i : output_locations.length
            output_locations << { "name" => m[3], "location" => location }
            out_lines << "#{m[2]} #{m[3]};"
            next
          end
          if (m = /\A\s*out\s+(\w+)\s+(\w+)\s*;\s*\z/.match(line))
            output_locations << { "name" => m[2], "location" => 0 }
            out_lines << "#{m[1]} #{m[2]};"
            next
          end
          if (m = /\A\s*(?:flat\s+)?in\s+(\w+)\s+(\w+)\s*;\s*\z/.match(line))
            varyings << m[2]
            next
          end
          out_lines << line
        end

        # Declare runtime-define uniforms (they were lowered to runtime branches).
        decls = ""
        runtime_defines.keys.sort.each do |name|
          t = runtime_defines[name] == "float" ? "float" : "int"
          decls += "uniform #{t} #{name};\n"
        end
        output_locations = [{ "name" => "fragColor", "location" => 0 }] if output_locations.empty?
        output_locations.sort_by! { |entry| entry["location"] }
        {
          "source" => decls + out_lines.join("\n"),
          "outputs" => output_locations.map { |entry| entry["name"] },
          "outputLocations" => output_locations,
          "varyings" => varyings,
        }
      end

      # Perl-truthiness-emulating check: `active`/`taken`/`outer` frame
      # fields (and _emitting's own return value) are always Integer 0/1;
      # Ruby's bare `if 0` is true, so every consumer compares explicitly.
      def self._emitting(stack)
        stack.each { |frame| return 0 if frame["active"] == 0 }
        1
      end

      def self._preprocess(source, runtime_defines)
        out = []
        defines = {}
        stack = [] # frames: {"kind" => static|runtime|include_all, "active", "taken", "outer"}
        depth = [0] # brace nesting of emitted content; boxed for closure mutation

        emit = lambda do |line|
          out << line
          depth[0] += line.count("{")
          depth[0] -= line.count("}")
        end

        source.split("\n", -1).each do |raw|
          s = raw.strip
          unless s.start_with?("#")
            emit.call(_expand(raw, defines)) if _emitting(stack) != 0
            next
          end
          d = s[1..].lstrip
          hm = /\A(\S+)/.match(d)
          head = hm ? hm[1] : ""
          next if %w[version extension pragma line].include?(head)

          case head
          when "define"
            if _emitting(stack) != 0 && d !~ /\Adefine\s+\w+\(/ # object-like only
              m = /\Adefine\s+(\w+)(?:\s+(.*))?\z/.match(d)
              if m
                val = (m[2] || "").strip
                defines[m[1]] = val
              end
            end
            next
          when "undef"
            if _emitting(stack) != 0
              name = d.split(/\s+/)[1]
              defines.delete(name) unless name.nil?
            end
            next
          when "ifdef", "ifndef", "if"
            outer = _emitting(stack)
            if outer != 0 && _cond_runtime(d, head, runtime_defines) != 0
              if depth[0] == 0
                # Global-scope runtime #if gates whole declarations -- include
                # ALL branches; runtime dispatch happens at statement scope.
                stack << { "kind" => "include_all", "active" => 1, "taken" => 1, "outer" => outer }
              else
                emit.call("if (#{_glsl_cond(d, head, defines)}) {")
                stack << { "kind" => "runtime", "active" => 1, "taken" => 1, "outer" => outer }
              end
            else
              val = outer != 0 ? _eval_cond(d, head, defines, runtime_defines) : 0
              stack << {
                "kind" => "static",
                "active" => (outer != 0 && val != 0) ? 1 : 0,
                "taken" => val,
                "outer" => outer,
              }
            end
            next
          when "elif"
            fr = stack[-1]
            if fr["kind"] == "include_all"
              # every branch is emitted
            elsif fr["kind"] == "runtime"
              emit.call("} else if (#{_glsl_cond(d, "if", defines)}) {")
              fr["active"] = 1
            elsif fr["taken"] != 0
              fr["active"] = 0
            else
              val = fr["outer"] != 0 ? _eval_cond(d, "if", defines, runtime_defines) : 0
              fr["active"] = (fr["outer"] != 0 && val != 0) ? 1 : 0
              fr["taken"] = val if fr["taken"] == 0
            end
            next
          when "else"
            fr = stack[-1]
            if fr["kind"] == "include_all"
              # every branch is emitted
            elsif fr["kind"] == "runtime"
              emit.call("} else {")
              fr["active"] = 1
            else
              fr["active"] = (fr["outer"] != 0 && fr["taken"] == 0) ? 1 : 0
              fr["taken"] = 1
            end
            next
          when "endif"
            fr = stack.pop
            emit.call("}") if fr && fr["kind"] == "runtime"
            next
          end
          next # unknown directive
        end
        out.join("\n")
      end

      def self._expand(line, defines)
        return line if defines.empty?

        16.times do
          changed = false
          line = line.gsub(/\b[A-Za-z_]\w*\b/) do |m|
            if defines.key?(m)
              changed = true
              defines[m]
            else
              m
            end
          end
          break unless changed
        end
        line
      end

      def self._cond_runtime(directive, head, runtime_defines)
        # #ifdef/#ifndef are about DEFINEDNESS: a runtime define is always
        # "defined" (bound as a uniform). Only `#if <expr>` needs lowering.
        return 0 if runtime_defines.empty? || head == "ifdef" || head == "ifndef"

        idents = {}
        directive.scan(/\b([A-Za-z_]\w*)\b/) { |mm| idents[mm[0]] = true }
        runtime_defines.each_key { |rd| return 1 if idents[rd] }
        0
      end

      def self._strip_kw(directive)
        directive.sub(/\A(?:elif|ifdef|ifndef|if)\b\s*/, "").strip
      end

      def self._glsl_cond(directive, head, defines)
        return "true" if head == "ifdef"
        return "false" if head == "ifndef"

        _expand(_strip_kw(directive), defines)
      end

      def self._eval_cond(directive, head, defines, runtime_defines)
        if head == "ifdef" || head == "ifndef"
          n = directive.split(/\s+/)[1]
          defined_flag = (!n.nil? && (defines.key?(n) || runtime_defines.key?(n))) ? 1 : 0
          return head == "ifdef" ? defined_flag : (1 - defined_flag)
        end
        expr = _strip_kw(directive)
        expr = expr.gsub(/defined\s*\(\s*(\w+)\s*\)/) { defines.key?(::Regexp.last_match(1)) ? "1" : "0" }
        expr = expr.gsub(/defined\s+(\w+)/) { defines.key?(::Regexp.last_match(1)) ? "1" : "0" }
        expr = _expand(expr, defines)
        # Hex literals evaluate numerically (translate before the letter scrub
        # below would zero the 'x').
        expr = expr.gsub(/\b0[xX][0-9a-fA-F]+\b/) { |m| m.to_i(16).to_s }
        # undefined identifiers evaluate to 0 in C/GLSL #if; keep true/false
        expr = expr.gsub(/\b[A-Za-z_]\w*\b/) { |m| (m == "true" || m == "false") ? m : "0" }
        expr = expr.gsub(/\btrue\b/, "1")
        expr = expr.gsub(/\bfalse\b/, "0")
        # Only arithmetic/comparison/logic characters may remain.
        return 0 if expr =~ %r{[^\d\s()<>=!&|^+\-*/%~]}

        result = _eval_expr(expr)
        result.zero? ? 0 : 1
      rescue StandardError
        0
      end

      # ---- tiny evaluator for sanitized #if expressions ----
      #
      # Stand-in for Perl's `eval $expr` on the numeric/logical residue of a
      # preprocessor #if directive. Ruby's own eval() can't be reused here:
      # Perl/C truthiness treats integer 0 as FALSE, but Ruby's &&/||/ternary
      # treat 0 as TRUE (Ruby trap #1 reaches our own codegen logic, not just
      # emitted kernel code) -- `eval("0 || 5")` would short-circuit to 0 in
      # Ruby where Perl's `eval` returns 5. This hand-rolled recursive-descent
      # evaluator reproduces C/Perl numeric truthiness and returns a strict
      # Integer/Float, matching what `_eval_cond`'s final `$result ? 1 : 0`
      # needs.
      EXPR_LEVELS = [
        ["||"],
        ["&&"],
        ["|"],
        ["^"],
        ["&"],
        ["==", "!="],
        ["<=", ">=", "<", ">"],
        ["<<", ">>"],
        ["+", "-"],
        ["*", "/", "%"],
      ].freeze

      def self._eval_expr(expr)
        toks = expr.scan(%r{<<|>>|<=|>=|==|!=|&&|\|\||[-+*/%~&|^<>!()]|\d+})
        pos = [0]
        v = _expr_binary(toks, pos, 0)
        raise "trailing input in #if expression" unless pos[0] == toks.length

        v
      end

      def self._expr_peek(toks, pos)
        toks[pos[0]]
      end

      def self._expr_next(toks, pos)
        t = toks[pos[0]]
        pos[0] += 1
        t
      end

      def self._expr_primary(toks, pos)
        t = _expr_peek(toks, pos)
        raise "unexpected end of #if expression" if t.nil?

        if t == "("
          _expr_next(toks, pos)
          v = _expr_binary(toks, pos, 0)
          raise "expected ) in #if expression" unless _expr_peek(toks, pos) == ")"

          _expr_next(toks, pos)
          v
        elsif t =~ /\A\d+\z/
          _expr_next(toks, pos)
          t.to_i
        else
          raise "unexpected token '#{t}' in #if expression"
        end
      end

      def self._expr_unary(toks, pos)
        case _expr_peek(toks, pos)
        when "!"
          _expr_next(toks, pos)
          _expr_unary(toks, pos).zero? ? 1 : 0
        when "~"
          _expr_next(toks, pos)
          ~_expr_unary(toks, pos)
        when "-"
          _expr_next(toks, pos)
          -_expr_unary(toks, pos)
        when "+"
          _expr_next(toks, pos)
          _expr_unary(toks, pos)
        else
          _expr_primary(toks, pos)
        end
      end

      def self._expr_binary(toks, pos, level)
        return _expr_unary(toks, pos) if level >= EXPR_LEVELS.length

        left = _expr_binary(toks, pos, level + 1)
        while EXPR_LEVELS[level].include?(_expr_peek(toks, pos))
          op = _expr_next(toks, pos)
          right = _expr_binary(toks, pos, level + 1)
          left = _expr_apply(op, left, right)
        end
        left
      end

      def self._expr_apply(op, left, right)
        case op
        when "||" then (left != 0 || right != 0) ? 1 : 0
        when "&&" then (left != 0 && right != 0) ? 1 : 0
        when "|" then left | right
        when "^" then left ^ right
        when "&" then left & right
        when "==" then left == right ? 1 : 0
        when "!=" then left != right ? 1 : 0
        when "<=" then left <= right ? 1 : 0
        when ">=" then left >= right ? 1 : 0
        when "<" then left < right ? 1 : 0
        when ">" then left > right ? 1 : 0
        when "<<" then left << right
        when ">>" then left >> right
        when "+" then left + right
        when "-" then left - right
        when "*" then left * right
        when "/" then left.fdiv(right) # Perl's `/` is always float (trap #2)
        when "%" then left % right
        end
      end
    end
  end
end
