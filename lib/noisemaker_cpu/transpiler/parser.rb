# frozen_string_literal: true

# GLSL ES 3.00 recursive-descent parser -> clean AST.
#
# AST nodes are Hashes with a "k" (kind) field, string keys throughout
# (mirrors Perl's hashref-of-strings AST and Python's dict AST 1:1). Consumes
# tokens from Lexer.tokenize on already-preprocessed GLSL.

require_relative "lexer"

module NoisemakerCpu
  module Transpiler
    class Parser
      SCALAR = %w[void bool int uint float].freeze
      VEC = ["", "i", "u", "b"].flat_map { |p| [2, 3, 4].map { |n| "#{p}vec#{n}" } }.freeze
      MAT = ([2, 3, 4].map { |n| "mat#{n}" } +
             [2, 3, 4].flat_map { |a| [2, 3, 4].map { |b| "mat#{a}x#{b}" } }).freeze
      SAMPLER = %w[sampler2D sampler3D samplerCube sampler2DArray].freeze
      TYPES = (SCALAR + VEC + MAT + SAMPLER).each_with_object({}) { |t, h| h[t] = true }.freeze

      QUALIFIERS = %w[
        const uniform in out inout flat smooth noperspective centroid invariant
        highp mediump lowp precise
      ].each_with_object({}) { |q, h| h[q] = true }.freeze

      ASSIGN = %w[= += -= *= /= %= &= |= ^= <<= >>=].each_with_object({}) { |o, h| h[o] = true }.freeze

      def initialize(tokens)
        @toks = tokens
        @i = 0
        @struct_types = {}
      end

      # ---- cursor ----
      def peek(k = 0)
        @toks[@i + k]
      end

      def at(value)
        @toks[@i]["value"] == value
      end

      def at_type
        t = peek
        t["kind"] == "id" && (TYPES[t["value"]] || @struct_types[t["value"]])
      end

      def next_tok
        t = @toks[@i]
        @i += 1
        t
      end

      def expect(value)
        t = @toks[@i]
        raise "expected '#{value}' got '#{t["value"]}' at token #{@i}\n" if t["value"] != value

        @i += 1
        t
      end

      def eat(value)
        if @toks[@i]["value"] == value
          @i += 1
          return true
        end
        false
      end

      # ---- top level ----
      def parse_program
        decls = []
        until at("<eof>")
          d = external_decl
          decls << d unless d.nil?
        end
        { "k" => "program", "decls" => decls }
      end

      def external_decl
        if at("precision")
          next_tok until eat(";")
          return nil
        end
        return struct_decl if at("struct")

        quals = qualifiers
        # interface (uniform) block: `uniform Name { members } [inst];`
        if quals.include?("uniform") && peek["kind"] == "id" && peek(1)["value"] == "{"
          return uniform_block
        end

        typ = type_spec
        name = next_tok["value"]
        return function_rest(typ, name, quals) if at("(")

        var_decl_rest(typ, name, quals, true)
      end

      def uniform_block
        next_tok # block type name (irrelevant without an instance)
        expect("{")
        members = []
        until at("}")
          qualifiers
          mtype = type_spec
          mname = next_tok["value"]
          arr = nil
          if eat("[")
            arr = expr
            expect("]")
          end
          members << { "type" => mtype, "name" => mname, "array" => arr }
          expect(";")
        end
        expect("}")
        inst = peek["kind"] == "id" ? next_tok["value"] : nil
        expect(";")
        { "k" => "ubo", "members" => members, "inst" => inst }
      end

      def qualifiers
        q = []
        loop do
          t = peek
          if t["value"] == "layout"
            next_tok
            expect("(")
            depth = 1
            while depth > 0
              v = next_tok["value"]
              depth += 1 if v == "("
              depth -= 1 if v == ")"
            end
            next
          end
          if t["kind"] == "id" && QUALIFIERS[t["value"]]
            q << next_tok["value"]
            next
          end
          break
        end
        q
      end

      def type_spec
        next_tok["value"]
      end

      def struct_decl
        expect("struct")
        name = next_tok["value"]
        @struct_types[name] = true
        expect("{")
        fields = []
        until at("}")
          qualifiers
          ftype = type_spec
          fname = next_tok["value"]
          arr = nil
          if eat("[")
            arr = expr
            expect("]")
          end
          fields << [ftype, fname, arr]
          expect(";")
        end
        expect("}")
        inst = peek["kind"] == "id" ? next_tok["value"] : nil
        expect(";")
        { "k" => "struct", "name" => name, "fields" => fields, "inst" => inst }
      end

      def function_rest(ret, name, _quals)
        expect("(")
        params = []
        unless at(")")
          loop do
            pquals = qualifiers
            if at("void") && peek(1)["value"] == ")"
              next_tok
              break
            end
            ptype = type_spec
            pname = peek["kind"] == "id" ? next_tok["value"] : nil
            if eat("[")
              expr
              expect("]")
            end
            params << [ptype, pname, pquals]
            break unless eat(",")
          end
        end
        expect(")")
        if eat(";") # prototype
          return { "k" => "proto", "ret" => ret, "name" => name, "params" => params }
        end
        body = block
        { "k" => "func", "ret" => ret, "name" => name, "params" => params, "body" => body }
      end

      def var_decl_rest(typ, name, quals, top)
        declarators = []
        loop do
          arr = nil
          if eat("[")
            arr = at("]") ? "unsized" : expr
            expect("]")
          end
          init = eat("=") ? assign_expr : nil
          declarators << { "name" => name, "array" => arr, "init" => init }
          break unless eat(",")

          name = next_tok["value"]
        end
        expect(";")
        { "k" => "decl", "type" => typ, "quals" => quals, "declarators" => declarators, "top" => top ? 1 : 0 }
      end

      # ---- statements ----
      def block
        expect("{")
        stmts = []
        stmts << statement until at("}")
        expect("}")
        stmts
      end

      def statement
        t = peek
        return { "k" => "block", "body" => block } if t["value"] == "{"
        return if_stmt if t["value"] == "if"
        return for_stmt if t["value"] == "for"

        if t["value"] == "while"
          next_tok
          expect("(")
          cond = expr
          expect(")")
          return { "k" => "while", "cond" => cond, "body" => statement }
        end
        if t["value"] == "do"
          next_tok
          body = statement
          expect("while")
          expect("(")
          cond = expr
          expect(")")
          expect(";")
          return { "k" => "dowhile", "cond" => cond, "body" => body }
        end
        if t["value"] == "return"
          next_tok
          val = at(";") ? nil : expr
          expect(";")
          return { "k" => "return", "value" => val }
        end
        if t["value"] == "break"
          next_tok
          expect(";")
          return { "k" => "break" }
        end
        if t["value"] == "continue"
          next_tok
          expect(";")
          return { "k" => "continue" }
        end
        if t["value"] == "discard"
          next_tok
          expect(";")
          return { "k" => "discard" }
        end
        if at_decl_start
          quals = qualifiers
          typ = type_spec
          name = next_tok["value"]
          return var_decl_rest(typ, name, quals, false)
        end
        e = expr
        expect(";")
        { "k" => "expr", "expr" => e }
      end

      def at_decl_start
        t = peek
        return false if t["kind"] != "id"
        return true if QUALIFIERS[t["value"]]

        if TYPES[t["value"]] || @struct_types[t["value"]]
          # a type keyword followed by an ident (decl) or by `(` (constructor)
          return peek(1)["kind"] == "id"
        end
        false
      end

      def if_stmt
        next_tok
        expect("(")
        cond = expr
        expect(")")
        then_ = statement
        els = eat("else") ? statement : nil
        { "k" => "if", "cond" => cond, "then" => then_, "els" => els }
      end

      def for_stmt
        next_tok
        expect("(")
        init =
          if eat(";")
            nil
          elsif at_decl_start
            quals = qualifiers
            typ = type_spec
            name = next_tok["value"]
            var_decl_rest(typ, name, quals, false)
          else
            e = { "k" => "expr", "expr" => expr }
            expect(";")
            e
          end
        cond = at(";") ? nil : expr
        expect(";")
        update = at(")") ? nil : expr
        expect(")")
        body = statement
        { "k" => "for", "init" => init, "cond" => cond, "update" => update, "body" => body }
      end

      # ---- expressions (precedence climbing) ----
      def expr
        e = assign_expr
        while at(",") # comma operator: keep last
          next_tok
          e = assign_expr
        end
        e
      end

      def assign_expr
        left = conditional
        if ASSIGN[peek["value"]]
          op = next_tok["value"]
          right = assign_expr
          return { "k" => "assign", "op" => op, "target" => left, "value" => right }
        end
        left
      end

      def conditional
        c = binary_expr(0)
        if eat("?")
          a = expr
          expect(":")
          b = assign_expr
          return { "k" => "cond", "c" => c, "a" => a, "b" => b }
        end
        c
      end

      BIN = [
        { "||" => true },
        { "&&" => true },
        { "|" => true },
        { "^" => true },
        { "&" => true },
        { "==" => true, "!=" => true },
        { "<" => true, ">" => true, "<=" => true, ">=" => true },
        { "<<" => true, ">>" => true },
        { "+" => true, "-" => true },
        { "*" => true, "/" => true, "%" => true },
      ].freeze

      def binary_expr(level)
        return unary_expr if level >= BIN.length

        left = binary_expr(level + 1)
        while BIN[level][peek["value"]]
          op = next_tok["value"]
          right = binary_expr(level + 1)
          left = { "k" => "binary", "op" => op, "l" => left, "r" => right }
        end
        left
      end

      def unary_expr
        t = peek
        if %w[+ - ! ~ ++ --].include?(t["value"])
          next_tok
          return { "k" => "unary", "op" => t["value"], "x" => unary_expr }
        end
        postfix
      end

      def postfix
        e = primary
        loop do
          t = peek
          case t["value"]
          when "."
            next_tok
            field = next_tok["value"]
            e =
              if at("(") && field == "length" # arr.length() -> array size
                expect("(")
                expect(")")
                { "k" => "call", "name" => "__array_length", "args" => [e] }
              else
                { "k" => "member", "obj" => e, "field" => field }
              end
          when "["
            next_tok
            idx = expr
            expect("]")
            e = { "k" => "index", "obj" => e, "idx" => idx }
          when "("
            e = call_rest(e)
          when "++", "--"
            next_tok
            e = { "k" => "post", "op" => t["value"], "x" => e }
          else
            break
          end
        end
        e
      end

      def call_rest(callee)
        expect("(")
        args = []
        unless at(")")
          loop do
            args << assign_expr
            break unless eat(",")
          end
        end
        expect(")")
        name = callee["k"] == "id" ? callee["name"] : callee["type"]
        { "k" => "call", "name" => name, "args" => args }
      end

      def primary
        t = peek
        if t["value"] == "("
          next_tok
          e = expr
          expect(")")
          return e
        end
        if t["kind"] == "num"
          next_tok
          return { "k" => "num", "value" => t["value"] }
        end
        if t["value"] == "true" || t["value"] == "false"
          next_tok
          return { "k" => "bool", "value" => t["value"] == "true" ? 1 : 0 }
        end
        if t["kind"] == "id"
          # constructor: TYPE(...) or TYPE[N](...)
          if (TYPES[t["value"]] || @struct_types[t["value"]]) &&
             (peek(1)["value"] == "(" || peek(1)["value"] == "[")
            next_tok
            arr = nil
            if eat("[")
              arr = at("]") ? "unsized" : expr
              expect("]")
            end
            expect("(")
            args = []
            unless at(")")
              loop do
                args << assign_expr
                break unless eat(",")
              end
            end
            expect(")")
            return { "k" => "construct", "type" => t["value"], "array" => arr, "args" => args }
          end
          next_tok
          return { "k" => "id", "name" => t["value"] }
        end
        raise "unexpected token '#{t["value"]}' at #{@i}\n"
      end

      def self.parse(source_or_tokens)
        tokens = source_or_tokens.is_a?(String) ? Lexer.tokenize(source_or_tokens) : source_or_tokens
        new(tokens).parse_program
      end
    end
  end
end
