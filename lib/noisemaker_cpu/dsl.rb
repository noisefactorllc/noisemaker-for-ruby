# frozen_string_literal: true

# Polymorphic DSL front-end: tokenizer + parser + compiler.
#
# Faithful port of the (parity-proven) Python DSL modules
# noisemaker_cpu/dsl/{error,tokenizer,parser,compiler}.py, themselves ports
# of noisemaker-cpu src/dsl/*.js. compile_dsl() lowers a program to a render
# plan that NoisemakerCpu::Renderer.render_dsl evaluates against the effect
# catalog (bundle metadata.json).
#
# Data conventions (the evaluator depends on these):
# - AST nodes are Hashes with STRING keys, matching the Python dicts ("kind",
#   "name", "value", "loc", "args", "argMode", "calls", "search", "bindings",
#   "chains", "render", ...); Python None -> nil, True/False -> Ruby's
#   true/false EXCEPT where noted below.
# - Tokens: { "type" =>, "lexeme" =>, "value" =>, "sourceName" =>, "line" =>,
#   "column" =>, "index" => }.
# - compile_dsl(source, effects, options) returns { "search" => [...],
#   "chains" => [...], "render_surface" => name }. Effect steps are
#   { "kind" => "effect", "effect_id" =>, "params" => {...},
#   "surfaces" => {...}, "loc" => }.
# - Surface markers: nil = leave unbound (blank 1x1), the string "@current"
#   = bind the chain's current image, ["surface", "oN"] = a named surface
#   (the Python port uses a tuple here).
# - Positional-arg mapping and the "accepted:" error listing use the
#   effect's paramOrder array from the metadata wherever Python used
#   list(param_specs.keys()): the bundle's record of the Python/JS param
#   dict order (this port's Hash preserves JSON.parse's key order too, but
#   paramOrder is kept as the single source of truth to stay 1:1 with Perl).
#
# Deliberate deviations from the Python source (reject-vs-accept space only;
# valid programs compile identically) -- carried over unchanged from the
# Perl port, which this file translates 1:1:
# - Python's _is_number excludes bool. Perl has no bool type (true/false lex
#   to the integers 1/0), so 1/0 pass as numbers -- e.g. vec2(true, 1)
#   compiles here where Python raises. This port deliberately reproduces
#   that Perl quirk rather than using Ruby's native true/false, so true/false
#   DSL literals lower to the Integers 1/0 here too (see parse_value_primary).
# - Numeric-looking DSL string literals ("1") pass the numeric check the
#   same way Perl's Scalar::Util::looks_like_number does (see
#   NUMBER_STRING_RE / _to_number below), including for arithmetic: Ruby has
#   no implicit string-to-number coercion on `+`/`-`/`*`, so binary/unary
#   arithmetic explicitly numifies through _to_number where Perl's operators
#   would do so implicitly.

require "set"

require_relative "automation"

module NoisemakerCpu
  module DSL
    UNSUPPORTED_INPUT = Object.new.freeze
    VALUE_CALLS = %w[osc midi audio].freeze
    KEYWORDS = %w[search let render true false subchain].each_with_object({}) { |k, h| h[k] = true }.freeze
    PUNCTUATION = "()[],.:=;{}".each_char.each_with_object({}) { |c, h| h[c] = true }.freeze
    OPERATORS = "+-*/".each_char.each_with_object({}) { |c, h| h[c] = true }.freeze

    # JSON-style string quoting for diagnostic text, matching Python
    # json.dumps(..., ensure_ascii=True) / Perl's JSON::PP->new->ascii, so
    # error messages stay byte-equal across the three ports.
    def self._json_quote(str)
      out = +"\""
      str.each_char do |ch|
        code = ch.ord
        case ch
        when "\\" then out << "\\\\"
        when "\"" then out << "\\\""
        when "\b" then out << "\\b"
        when "\f" then out << "\\f"
        when "\n" then out << "\\n"
        when "\r" then out << "\\r"
        when "\t" then out << "\\t"
        else
          if code < 0x20 || code > 0x7E
            if code > 0xFFFF
              v = code - 0x10000
              high = 0xD800 + (v >> 10)
              low = 0xDC00 + (v & 0x3FF)
              out << format("\\u%04x", high) << format("\\u%04x", low)
            else
              out << format("\\u%04x", code)
            end
          else
            out << ch
          end
        end
      end
      out << "\""
    end

    def self._jq(value)
      _json_quote(value.nil? ? "" : value.to_s)
    end

    # Every internal diagnostic goes through the located error object below.
    def self._throw(message, location = nil)
      raise Error.new(message, location)
    end

    # ---- tokenizer (port of dsl/tokenizer.py tokenize_dsl) ----

    def self.tokenize_dsl(source, options = nil)
      options = {} unless options.is_a?(Hash)
      raise "DSL source must be a string\n" unless source.is_a?(String)

      source_name = options["sourceName"] || "<dsl>"
      tokens = []
      length = source.length
      index = 0
      line = 1
      column = 1

      at = lambda do |offset|
        pos = index + offset
        (pos >= 0 && pos < length) ? source[pos] : ""
      end
      start = lambda do
        { "sourceName" => source_name, "line" => line, "column" => column, "index" => index }
      end
      # At end-of-source this returns "" instead of raising (mirrors the
      # Python/Perl ports, whose "advance" reads one past the end on e.g. a
      # trailing backslash inside an unterminated string); the enclosing
      # loop then raises the located Error.
      advance = lambda do
        char = index < length ? source[index] : ""
        index += 1
        if char == "\n"
          line += 1
          column = 1
        else
          column += 1
        end
        char
      end
      push_tok = lambda do |type, lexeme, location, value = nil|
        tokens << { "type" => type, "lexeme" => lexeme, "value" => value }.merge(location)
      end

      while index < length
        char = source[index]
        if char =~ /\s/
          advance.call
          next
        end
        if char == "/" && at.call(1) == "/"
          advance.call while index < length && source[index] != "\n"
          next
        end
        if char == "/" && at.call(1) == "*"
          location = start.call
          advance.call
          advance.call
          advance.call while index < length && !(source[index] == "*" && at.call(1) == "/")
          _throw("Unterminated block comment", location) if index >= length

          advance.call
          advance.call
          next
        end

        location = start.call
        if char == "#"
          lexeme = advance.call
          lexeme += advance.call while at.call(0) =~ /\A[0-9a-fA-F]\z/
          len = lexeme.length
          unless [4, 7, 9].include?(len)
            _throw("Colors must use #RGB, #RRGGBB, or #RRGGBBAA", location)
          end
          push_tok.call("color", lexeme, location, nil)
          next
        end
        # A triple-quoted string (upstream `String ::= '"""' .* '"""'`) may span lines.
        # Upstream's lexer keeps its content raw, without escape processing, and its
        # unparser writes a multi-line string in this form.
        if char == "\"" && at.call(1) == "\"" && at.call(2) == "\""
          closing = source.index("\"\"\"", index + 3)
          _throw("Unterminated string", location) if closing.nil?
          value = source[(index + 3)...closing]
          advance.call while index < closing + 3
          push_tok.call("string", value, location, value)
          next
        end
        if char == "\""
          advance.call
          value = +""
          while index < length && source[index] != "\""
            _throw("Unterminated string", location) if source[index] == "\n"
            if source[index] == "\\"
              advance.call
              escaped = advance.call
              value << (escaped == "n" ? "\n" : escaped == "t" ? "\t" : escaped)
            else
              value << advance.call
            end
          end
          _throw("Unterminated string", location) if index >= length

          advance.call
          push_tok.call("string", value, location, value)
          next
        end
        if char =~ /\A\d\z/ || (char == "." && at.call(1) =~ /\A\d\z/)
          lexeme = +""
          lexeme += advance.call while at.call(0) =~ /\A\d\z/
          if at.call(0) == "."
            lexeme += advance.call
            lexeme += advance.call while at.call(0) =~ /\A\d\z/
          end
          if at.call(0) == "e" || at.call(0) == "E"
            lexeme += advance.call
            lexeme += advance.call if at.call(0) == "+" || at.call(0) == "-"
            lexeme += advance.call while at.call(0) =~ /\A\d\z/
          end
          # A truncated exponent like "1e"/"1e+" fails this grammar check;
          # mirror with a strict grammar so every DSL failure stays a
          # located Error rather than a silent numify-to-garbage.
          unless lexeme =~ /\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
            _throw("Invalid numeric literal #{_jq(lexeme)}", location)
          end
          number_value = lexeme.match?(/[.eE]/) ? Float(lexeme) : Integer(lexeme, 10)
          push_tok.call("number", lexeme, location, number_value)
          next
        end
        if char =~ /\A[A-Za-z_]\z/
          lexeme = advance.call
          lexeme += advance.call while at.call(0) =~ /\A[A-Za-z0-9_]\z/
          type =
            if lexeme =~ /\Ao\d+\z/
              "surface"
            elsif KEYWORDS[lexeme]
              "keyword"
            else
              "identifier"
            end
          push_tok.call(type, lexeme, location, nil)
          next
        end
        if PUNCTUATION[char]
          advance.call
          push_tok.call("punctuation", char, location, nil)
          next
        end
        if OPERATORS[char]
          advance.call
          push_tok.call("operator", char, location, nil)
          next
        end
        _throw("Unexpected character #{_jq(char)}", location)
      end

      tokens << {
        "type" => "eof",
        "lexeme" => "",
        "value" => nil,
        "sourceName" => source_name,
        "line" => line,
        "column" => column,
        "index" => index,
      }
      tokens
    end

    # ---- parser (port of dsl/parser.py) ----

    def self._location(token)
      {
        "sourceName" => token["sourceName"],
        "line" => token["line"],
        "column" => token["column"],
        "index" => token["index"],
      }
    end

    def self._parse_color(lexeme)
      hexit = lexeme[1..]
      hexit = hexit.each_char.map { |c| c * 2 }.join if hexit.length == 3
      values = [0, 2, 4].map { |offset| Integer(hexit[offset, 2], 16).fdiv(255) }
      values << Integer(hexit[6, 2], 16).fdiv(255) if hexit.length == 8
      values
    end

    # File-scoped so the Parser class below shares it.
    PRECEDENCE = { "+" => 1, "-" => 1, "*" => 2, "/" => 2 }.freeze

    # Recursive-descent parser state -- port of parser.py class _Parser
    # (renamed Parser: Ruby's module nesting already gives it the same
    # "internal to DSL" scoping Perl's leading underscore signaled). Methods
    # keep the Python names; DSL._throw/DSL._location alias the outer
    # module's helpers (bare calls would resolve as Parser instance
    # methods, not DSL's, since method lookup ignores lexical nesting).
    class Parser
      def initialize(tokens)
        @tokens = tokens
        @current = 0
      end

      def peek(offset = 0)
        i = @current + offset
        i = @tokens.length - 1 if i > @tokens.length - 1
        @tokens[i]
      end

      # Note: at current == 0 this reads index -1 (the trailing eof token),
      # the same wraparound the Python port's tokens[self.current - 1]
      # produces.
      def previous
        @tokens[@current - 1]
      end

      def at_end?
        peek["type"] == "eof"
      end

      # A string token's lexeme is its content, so a string never matches
      # punctuation, an operator or a keyword: `text(")")` holds the string ")".
      def check(lexeme)
        peek["type"] != "string" && peek["lexeme"] == lexeme
      end

      def match(*lexemes)
        return false if peek["type"] == "string" || !lexemes.include?(peek["lexeme"])

        @current += 1
        true
      end

      def consume(lexeme, message = nil)
        DSL._throw(message || "Expected \"#{lexeme}\"", DSL._location(peek)) unless check(lexeme)

        token = @tokens[@current]
        @current += 1
        token
      end

      def identifier(message = "Expected identifier")
        token = peek
        DSL._throw(message, DSL._location(token)) unless token["type"] == "identifier"

        @current += 1
        token
      end

      def search_namespace
        token = peek
        valid = token["type"] == "identifier" ||
          (token["type"] == "keyword" && token["lexeme"] == "render")
        DSL._throw("Expected namespace after search", DSL._location(token)) unless valid

        @current += 1
        token
      end

      def parse_program
        ast = {
          "kind" => "DslProgram",
          "search" => [],
          "bindings" => [],
          "chains" => [],
          "render" => nil,
          "loc" => DSL._location(peek),
        }
        if match("search")
          loop do
            ast["search"] << search_namespace["lexeme"]
            break unless match(",")
          end
          match(";")
        end
        until at_end?
          if match(";")
            next
          elsif match("let")
            binding = parse_binding(previous)
            # Upstream 9cc041d0: statement order matters. A let's planIndex is
            # the number of chain statements written before it; a chain sees
            # only the lets declared at or before its own index. (The JS port
            # stores it non-enumerably so the AST JSON form stays unchanged;
            # this AST is never serialized, so the key is plain.)
            binding["planIndex"] = ast["chains"].length
            ast["bindings"] << binding
          elsif match("render")
            DSL._throw("Program may only declare one render surface", DSL._location(previous)) if ast["render"]

            start_tok = previous
            consume("(")
            ast["render"] = parse_surface
            ast["render"]["loc"] = DSL._location(start_tok)
            consume(")")
            match(";")
          else
            ast["chains"] << parse_chain
            match(";")
          end
        end
        ast
      end

      def parse_binding(start_tok)
        name = identifier("Expected binding name after let")
        consume("=")
        value =
          if peek["type"] == "identifier" && peek(1)["lexeme"] == "("
            parse_call
          else
            parse_value_expression
          end
        match(";")
        { "kind" => "Binding", "name" => name["lexeme"], "value" => value, "loc" => DSL._location(start_tok) }
      end

      def parse_chain
        first = parse_call
        calls = [first]
        loop do
          break unless match(".")

          if at_subchain?
            calls << parse_subchain
          elsif peek["lexeme"] == "write3d" && peek["type"] == "identifier"
            calls << parse_write3d
          else
            calls << parse_call
          end
        end
        { "kind" => "Chain", "calls" => calls, "loc" => first["loc"] }
      end

      # Port of upstream parseWriteCall for write3d: two positional references, a
      # volume and a geometry (`write3d(vol0, geo0)`), each an identifier or a
      # surface.
      def parse_write3d
        name = identifier
        consume("(")
        reference = lambda do
          token = peek
          return parse_surface if token["type"] == "surface"
          DSL._throw("Expected surface reference", DSL._location(token)) unless token["type"] == "identifier"

          @current += 1
          { "kind" => "identifier", "name" => token["lexeme"], "loc" => DSL._location(token) }
        end
        volume = reference.call
        consume(",")
        geometry = reference.call
        consume(")")
        args = [volume, geometry].map { |value| { "name" => nil, "value" => value, "loc" => value["loc"] } }
        { "kind" => "Call", "name" => "write3d", "args" => args, "argMode" => "positional",
          "loc" => DSL._location(name) }
      end

      def at_subchain?
        peek["type"] == "keyword" && peek["lexeme"] == "subchain"
      end

      def is_punctuation(lexeme)
        peek["type"] == "punctuation" && peek["lexeme"] == lexeme
      end

      # A chain in a value position (upstream parseChain in its 'expression'
      # context). It may hold subchain blocks, and it cannot hold write() or
      # write3d().
      def parse_expression_chain(first)
        calls = [first]
        while is_punctuation(".")
          @current += 1
          if at_subchain?
            calls << parse_subchain
            next
          end
          call = parse_call
          # Upstream allows write() and write3d() only in statement context.
          if call["name"] == "write" || call["name"] == "write3d"
            DSL._throw("Expected effect or IO function name", call["loc"])
          end
          calls << call
        end
        { "kind" => "Chain", "calls" => calls, "loc" => first["loc"] }
      end

      # Port of upstream parseSubchainCall: `subchain(name: "...", id: "...") { .a() .b() }`.
      # A single leading string is shorthand for `name`. Unknown keys, duplicate keys and
      # a missing ',' between keys are upstream warnings (P008-P010): the program still
      # compiles, an unknown key's value is discarded and the last duplicate wins. The
      # body holds one or more '.'-prefixed calls and cannot hold write(), write3d() or
      # another subchain, which upstream's lexer reserves as keywords.
      def parse_subchain
        start_tok = @tokens[@current]
        @current += 1
        consume("(")
        meta = { "name" => nil, "id" => nil }
        if peek["type"] == "string"
          meta["name"] = @tokens[@current]["value"]
          @current += 1
        else
          while peek["type"] == "identifier" && peek(1)["lexeme"] == ":"
            key = identifier["lexeme"]
            consume(":")
            # A value that is not a string ends the arguments, so the closing ')'
            # check below reports it.
            break unless peek["type"] == "string"

            value = @tokens[@current]["value"]
            @current += 1
            meta[key] = value if key == "name" || key == "id"
            match(",")
          end
        end
        consume(")")
        consume("{")
        # The body holds at least one element, so an empty block fails on its
        # missing '.'.
        body = []
        loop do
          consume(".")
          call = parse_call
          if call["name"] == "write" || call["name"] == "write3d"
            DSL._throw("Expected effect or IO function name", call["loc"])
          end
          body << call
          break if check("}")
        end
        consume("}")
        { "kind" => "Subchain", "name" => meta["name"] || nil, "id" => meta["id"] || nil, "body" => body,
          "loc" => DSL._location(start_tok) }
      end

      def parse_call
        name = identifier("Expected effect or IO function name")
        consume("(")
        args = []
        mode = nil
        # Upstream's parseCall lets the midi() and audio() value calls mix positional
        # and keyword arguments (`allowMixed`); every other call keeps one form.
        allow_mixed = name["lexeme"] == "midi" || name["lexeme"] == "audio"
        unless check(")")
          loop do
            is_named = peek["type"] == "identifier" && peek(1)["lexeme"] == ":"
            next_mode = is_named ? "named" : "positional"
            if mode && mode != next_mode && !allow_mixed
              DSL._throw("Cannot mix positional and named arguments", DSL._location(peek))
            end
            mode = mode && mode != next_mode ? "mixed" : next_mode
            arg_name = nil
            if is_named
              arg_name = identifier["lexeme"]
              consume(":")
            end
            start_tok = peek
            args << { "name" => arg_name, "value" => parse_value_expression, "loc" => DSL._location(start_tok) }
            break unless match(",")
          end
        end
        consume(")")
        call = { "kind" => "Call", "name" => name["lexeme"], "args" => args, "argMode" => mode,
                 "loc" => DSL._location(name) }
        call["name"] == "from" ? from_call(call) : call
      end

      # Port of upstream transformFromInvocation: `from(namespace, effect(...))` is the
      # effect call, resolved in that one namespace instead of the search order. It
      # takes exactly two positional arguments, an identifier and one call; upstream's
      # read(), read3d(), osc(), midi() and audio() nodes are not Call nodes. Any
      # other from(...) stays a call named `from`, which no namespace defines, so the
      # compiler rejects it as an unknown effect.
      def from_call(call)
        return call if call["argMode"] != "positional" || call["args"].length != 2

        namespace, target = call["args"].map { |arg| arg["value"] }
        inner = nil
        if target.is_a?(Hash) && target["kind"] == "Chain" && target["calls"].length == 1
          inner = target["calls"][0]
        end
        return call if !namespace.is_a?(Hash) || namespace["kind"] != "identifier" ||
                       !inner.is_a?(Hash) || inner["kind"] != "Call" ||
                       %w[read read3d write write3d].include?(inner["name"])

        inner.merge("namespace" => namespace["name"])
      end

      def parse_value_expression(min_precedence = 0)
        left = parse_value_unary
        loop do
          lex = peek["lexeme"]
          break unless peek["type"] == "operator" && PRECEDENCE.key?(lex)

          prec = PRECEDENCE[lex]
          break if prec < min_precedence

          operator = @tokens[@current]
          @current += 1
          right = parse_value_expression(PRECEDENCE[operator["lexeme"]] + 1)
          left = {
            "kind" => "binary",
            "operator" => operator["lexeme"],
            "left" => left,
            "right" => right,
            "loc" => DSL._location(operator),
          }
        end
        left
      end

      def parse_value_unary
        if match("-", "+")
          operator = previous
          return {
            "kind" => "unary",
            "operator" => operator["lexeme"],
            "argument" => parse_value_unary,
            "loc" => DSL._location(operator),
          }
        end
        parse_value_primary
      end

      def parse_value_primary
        token = peek
        if token["type"] == "number"
          @current += 1
          return token["value"]
        end
        if token["type"] == "string"
          @current += 1
          return token["value"]
        end
        if token["lexeme"] == "true" || token["lexeme"] == "false"
          # Perl has no bool type; true/false lower to Integer 1/0 (see the
          # module-level deviation note at the top of this file).
          @current += 1
          return token["lexeme"] == "true" ? 1 : 0
        end
        if token["type"] == "color"
          @current += 1
          return DSL._parse_color(token["lexeme"])
        end
        return parse_surface if token["type"] == "surface"

        if match("[")
          values = []
          unless check("]")
            loop do
              values << parse_value_expression
              break unless match(",")
            end
          end
          consume("]")
          return values
        end
        if match("(")
          value = parse_value_expression
          consume(")")
          return value
        end
        if token["type"] == "identifier"
          @current += 1
          name = token["lexeme"]
          # `Math.PI` is the one numeric constant of upstream's grammar
          # (`NumberExpr ::= Number | 'Math.PI' | ...`).
          if name == "Math" && is_punctuation(".") && peek(1)["type"] == "identifier" && peek(1)["lexeme"] == "PI"
            @current += 2
            return Math::PI
          end
          # A one-argument `read3d(vol0)` names a volume or geometry for a parameter,
          # as upstream's validator reads it. With two arguments it starts a chain.
          if name == "read3d" && is_punctuation("(")
            @current -= 1
            call = parse_call
            first = call["args"][0]
            if call["args"].length == 1 && first["value"].is_a?(Hash) && first["value"]["kind"] == "identifier"
              return first["value"]
            end
            return parse_expression_chain(call)
          end
          if name == "read" && match("(")
            if peek["type"] == "identifier" && peek(1)["lexeme"] == ":"
              argument_name = identifier["lexeme"]
              if argument_name != "surface" && argument_name != "tex"
                DSL._throw('read() surface argument must be named "surface" or "tex"', DSL._location(previous))
              end
              consume(":")
            end
            surface = parse_surface
            consume(")")
            # `read(oN).effect()` in a value position is a chain argument that starts
            # from the surface. A bare `read(oN)` stays a plain surface reference.
            if is_punctuation(".")
              read_call = {
                "kind" => "Call", "name" => "read",
                "args" => [{ "name" => nil, "value" => surface, "loc" => surface["loc"] }],
                "argMode" => "positional", "loc" => DSL._location(token),
              }
              return parse_expression_chain(read_call)
            end
            return surface
          end
          if %w[vec2 vec3 vec4].include?(name) && match("(")
            values = []
            unless check(")")
              loop do
                values << parse_value_expression
                break unless match(",")
              end
            end
            consume(")")
            return { "kind" => "vector", "width" => Integer(name[-1], 10), "values" => values,
                      "loc" => DSL._location(token) }
          end
          # MIDI/audio calls are parsed only for unsupported-input warnings.
          if VALUE_CALLS.include?(name) && peek["lexeme"] == "("
            @current -= 1
            return parse_call
          end
          # Any other call in a value position starts a chain argument
          # (upstream `Expr ::= Chain`), for example `tex: solid(color: #f00)`.
          if is_punctuation("(")
            @current -= 1
            return parse_expression_chain(parse_call)
          end
          path = name
          while match(".")
            path += ".#{identifier('Expected enum member')['lexeme']}"
          end
          return { "kind" => "identifier", "name" => path, "loc" => DSL._location(token) }
        end
        DSL._throw("Expected DSL value", DSL._location(token))
      end

      def parse_surface
        token = peek
        DSL._throw("Expected surface reference", DSL._location(token)) unless token["type"] == "surface"

        @current += 1
        index = Integer(token["lexeme"][1..], 10)
        if index < 0 || index > 7
          DSL._throw("Surface reference must be o0 through o7", DSL._location(token))
        end
        { "kind" => "surface", "name" => token["lexeme"], "loc" => DSL._location(token) }
      end
    end

    def self.parse_dsl(source, options = nil)
      options = {} unless options.is_a?(Hash)
      Parser.new(tokenize_dsl(source, options)).parse_program
    end

    # ---- compiler (port of dsl/compiler.py) ----
    #
    # Resolves each call against the effect catalog, merges `let` partials,
    # evaluates value expressions/bindings, and lowers every chain into a
    # flat list of read/write/effect steps. Effect steps split arguments
    # into value params (handed to render_effect, which coerces + fills
    # defaults) and surface bindings, applying each surface param's own
    # default ("inputTex"/"none") exactly as the JS engine does.

    # Mirrors upstream std_enums.js oscKind (sine..noise2d; noise/noise1d alias
    # kind 5, noise2d is the two-stage periodic noise added upstream at
    # eabb537e). Port of the CPU compiler's compileOscillator (dsl/compiler.js).
    OSC_KINDS = {
      "sine" => 0, "tri" => 1, "saw" => 2, "sawInv" => 3, "square" => 4,
      "noise" => 5, "noise1d" => 5, "noise2d" => 6,
    }.freeze
    OSC_PARAM_ORDER = %w[type min max speed offset seed].freeze
    MAX_AUTOMATION_DEPTH = 8

    # The `let` bindings of a program, plus the compiler of chain arguments. A chain in
    # an argument (`tex: solid(color: #f00)`) compiles to its own chain that writes a
    # hidden surface. The consuming step carries it in `inline_chains`, and the
    # renderer runs it before the step, as upstream's validator compiles the chain into
    # temporary steps ahead of the consuming effect.
    class Scope < Hash
      attr_accessor :registry, :search, :pending, :inline_count
      # Names of the program's lets that a later statement declares. Reading one
      # before its let reports S003, as upstream's validator does.
      attr_accessor :pending_names

      def initialize(registry, search)
        super()
        @registry = registry
        @search = search
        @pending = nil
        @inline_count = 0
        @pending_names = nil
      end

      def compile_inline_chain(chain)
        compiled = DSL._compile_chain(chain, self, inline: true)
        surface = "inline:#{@inline_count}"
        @inline_count += 1
        @pending << { "surface" => surface, "chain" => compiled }
        { "kind" => "surface", "name" => surface, "loc" => chain["loc"] }
      end
    end

    # Compiles an `osc(...)` value-position call into the automation value shape the
    # runtime evaluator consumes ({"type" => "Oscillator", "oscType" =>, "min" =>,
    # "max" =>, "speed" =>, "offset" =>, "seed" =>}), mirroring upstream's parser
    # transformOscInvocation plus the validator's compileAutomationDescriptor:
    # positional args fill type/min/max/speed/offset/seed in order, kwargs select
    # by name, every field defaults as upstream defaults, min/max clamp into
    # [0,1], nested osc() fields are allowed, and the oscType resolves from an
    # integer 0..6 or an oscKind name (bare or oscKind-qualified). Invalid
    # programs raise a located Error, as everywhere else in this compiler.
    def self._compile_oscillator(call, bindings, depth, resolving = [])
      if depth > MAX_AUTOMATION_DEPTH
        _throw("Automation nesting exceeds the maximum depth of #{MAX_AUTOMATION_DEPTH}", call["loc"])
      end
      fields = {}
      if call["argMode"] == "named"
        call["args"].each do |arg|
          unless OSC_PARAM_ORDER.include?(arg["name"])
            _throw("osc() unknown parameter '#{arg['name']}'; valid: #{OSC_PARAM_ORDER.join(', ')}", call["loc"])
          end
          fields[arg["name"]] = arg["value"]
        end
      else
        call["args"].each_with_index do |arg, index|
          fields[OSC_PARAM_ORDER[index]] = arg["value"] if index < OSC_PARAM_ORDER.length
        end
      end

      raw_type = fields.key?("type") ? _evaluate_value(fields["type"], bindings, depth + 1, resolving) : 0
      osc_type =
        if raw_type.is_a?(Numeric) && raw_type.to_f.finite? && raw_type == raw_type.to_i
          unless raw_type.to_i >= 0 && raw_type.to_i <= 6
            _throw("osc() type must resolve to a supported oscKind value (0-6)", call["loc"])
          end
          raw_type.to_i
        elsif raw_type.is_a?(String)
          kind_name = raw_type.start_with?("oscKind.") ? raw_type["oscKind.".length..] : raw_type
          unless OSC_KINDS.key?(kind_name)
            _throw("osc() type must resolve to a supported oscKind value; got \"#{raw_type}\"", call["loc"])
          end
          OSC_KINDS[kind_name]
        else
          _throw("osc() type must resolve to a supported oscKind value", call["loc"])
        end

      number_field = lambda do |node, name, fallback, clamp|
        return fallback if node.nil?

        value = _evaluate_value(node, bindings, depth + 1, resolving)
        return fallback if value.equal?(UNSUPPORTED_INPUT)
        return value if Automation.automation_value?(value)
        return 1 if value == true
        return 0 if value == false

        unless value.is_a?(Numeric) && value.to_f.finite?
          _throw("osc() #{name} must be a number or a nested osc()", call["loc"])
        end
        clamp ? _clamp01(value) : value
      end

      {
        "type" => "Oscillator",
        "oscType" => osc_type,
        "min" => number_field.call(fields["min"], "min", 0, true),
        "max" => number_field.call(fields["max"], "max", 1, true),
        "speed" => number_field.call(fields["speed"], "speed", 1, false),
        "offset" => number_field.call(fields["offset"], "offset", 0, false),
        "seed" => number_field.call(fields["seed"], "seed", 1, false),
      }
    end

    # Math.max(0, Math.min(1, value)) for an already-validated finite number.
    def self._clamp01(value)
      [[value, 1.0].min, 0.0].max
    end

    # Perl's Scalar::Util::looks_like_number, approximated: signed
    # int/float/exponent forms plus Inf/Infinity/NaN (any case), optional
    # surrounding whitespace.
    NUMBER_STRING_RE = /\A\s*[+-]?(?:\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|inf(?:inity)?|nan)\s*\z/i

    def self._looks_like_number(str)
      !!(str =~ NUMBER_STRING_RE)
    end

    def self._is_number(value)
      return true if value.is_a?(Numeric)
      return _looks_like_number(value) if value.is_a?(String)

      false
    end

    def self._is_surface(value)
      value.is_a?(Hash) && value["kind"] == "surface"
    end

    # Ruby (unlike Perl) has no implicit string->number coercion on
    # `+`/`-`/`*`, so binary/unary arithmetic below numifies explicitly
    # through here wherever Perl's operators would numify a
    # looks_like_number string automatically.
    def self._to_number(value)
      return value if value.is_a?(Numeric)

      s = value.strip
      case s
      when /\A[+-]?inf(?:inity)?\z/i
        s.start_with?("-") ? -Float::INFINITY : Float::INFINITY
      when /\Anan\z/i
        Float::NAN
      else
        s.match?(/[.eE]/) ? Float(s) : Integer(s, 10)
      end
    end

    # `resolving` threads the chain of binding names currently being resolved so a
    # cyclic let set (`let a = b`, `let b = a`) fails instead of looping forever,
    # as upstream's validator substitution detects the same cycle.
    def self._evaluate_value(value, bindings, osc_depth = 0, resolving = [])
      # JS's Array branch recurses without the depth argument (mirrored).
      return value.map { |item| _evaluate_value(item, bindings, osc_depth, resolving) } if value.is_a?(Array)
      return value unless value.is_a?(Hash)

      kind = value["kind"] || ""
      case kind
      when "surface"
        value
      when "Call"
        if %w[midi audio].include?(value["name"])
          warn "Warning: #{value['name']}() is unsupported in CPU ports; real-time input is unavailable. Ignoring this unsupported input value."
          return UNSUPPORTED_INPUT
        end
        if value["name"] == "osc"
          return _compile_oscillator(value, bindings, osc_depth, resolving)
        end
        _throw("Unsupported DSL value #{kind} \"#{value['name']}\"", value["loc"])
      when "identifier"
        name = value["name"]
        if bindings.key?(name)
          binding = bindings[name]
          if binding["kind"] == "partial"
            _throw("Effect partial \"#{name}\" cannot be used as a value", value["loc"])
          end
          # An effect alias used as a value stays the effect's bare name.
          return binding["name"] if binding["kind"] == "alias"

          # A value binding resolves lazily at its first use. Statement order
          # (upstream 9cc041d0) makes a chain see only lets declared at or before
          # its own index, so a name declared by a later let is pending here and
          # reading it reports S003, as upstream does.
          return binding["value"] if binding["resolved"]

          if resolving.include?(name)
            _throw("Automation cycle detected: #{(resolving + [name]).join(' -> ')}", value["loc"])
          end
          binding["value"] = _evaluate_value(binding["expr"], bindings, osc_depth, resolving + [name])
          binding["resolved"] = true
          return binding["value"]
        end
        if bindings.respond_to?(:pending_names) && bindings.pending_names&.include?(name)
          _throw("Variable used before assignment: '#{name}'", value["loc"])
        end
        name
      when "Chain"
        return bindings.compile_inline_chain(value) if bindings.respond_to?(:pending) && bindings.pending

        _throw("Unsupported DSL value #{kind}", value["loc"])
      when "vector"
        # JS's evaluateValue recursion here resets the osc depth (vector,
        # unary and binary operands call evaluateValue without the depth
        # argument); mirror that exactly.
        components = value["values"].map { |item| _evaluate_value(item, bindings, 0, resolving) }
        width = value["width"]
        if components.length != width || components.any? { |c| !_is_number(c) }
          _throw("vec#{width} requires #{width} numeric values", value["loc"])
        end
        components
      when "unary"
        operand = _evaluate_value(value["argument"], bindings, 0, resolving)
        _throw("Unary arithmetic requires a number", value["loc"]) unless _is_number(operand)
        # Perl's unary '+' is a passthrough (does not force numeric
        # conversion); only '-' does, via negation. Preserve that asymmetry.
        value["operator"] == "-" ? -_to_number(operand) : operand
      when "binary"
        left = _evaluate_value(value["left"], bindings, 0, resolving)
        right = _evaluate_value(value["right"], bindings, 0, resolving)
        unless _is_number(left) && _is_number(right)
          _throw("Arithmetic requires numeric values", value["loc"])
        end
        left = _to_number(left)
        right = _to_number(right)
        case value["operator"]
        when "+" then left + right
        when "-" then left - right
        when "*" then left * right
        else left.fdiv(right) # Perl '/' is always float division (Ruby trap #2).
        end
      else
        _throw("Unsupported DSL value #{kind}", value["loc"])
      end
    end

    def self._resolve_args(args, bindings)
      args.map { |arg| arg.merge("value" => _evaluate_value(arg["value"], bindings)) }
    end

    def self._merge_args(stored, call)
      return call.merge("name" => stored["name"]) unless stored["argMode"]
      return stored.merge("loc" => call["loc"]) unless call["argMode"]

      if stored["argMode"] != call["argMode"]
        _throw("Partial and call arguments must use the same named or positional form", call["loc"])
      end
      if stored["argMode"] == "positional"
        return call.merge("name" => stored["name"], "args" => stored["args"] + call["args"])
      end

      # Named merge preserves insertion order: stored names first (a
      # re-supplied name keeps its slot, value overridden), new names appended.
      merged = {}
      order = []
      (stored["args"] + call["args"]).each do |arg|
        order << arg["name"] unless merged.key?(arg["name"])
        merged[arg["name"]] = arg
      end
      call.merge("name" => stored["name"], "args" => order.map { |n| merged[n] }, "argMode" => "named")
    end

    # A `from(ns, ...)` namespace on the call site wins over one stored in the
    # partial, as in upstream's resolveCall.
    def self._merge_partial(stored, call)
      merged = _merge_args(stored, call)
      namespace = call["namespace"] || stored["namespace"]
      if namespace
        merged["namespace"] = namespace
      else
        merged.delete("namespace")
      end
      merged
    end

    def self._resolve_effect(func, search, effects)
      search.each do |namespace|
        effect_id = "#{namespace}/#{func}"
        return effect_id if effects.key?(effect_id)
      end
      nil
    end

    # Lower a surface argument (or a param's own default) to an evaluator
    # binding: nil means leave unbound (a blank 1x1, matching JS
    # emptySurface), "@current" binds the chain's current image,
    # ["surface", "oN"] a named surface.
    def self._surface_marker(value, name, loc)
      return nil if value.nil? || (!value.is_a?(Hash) && value == "none")
      return "@current" if !value.is_a?(Hash) && value == "inputTex"
      return ["surface", value["name"]] if _is_surface(value)

      _throw("Parameter \"#{name}\" must be a surface reference", loc)
    end

    # Split value parameters from surface bindings. Renderer validates and
    # coerces values for both direct calls and compiled DSL steps.
    def self._normalize_effect(effect_id, spec, args)
      param_specs = spec["params"]
      param_names = spec["paramOrder"]
      aliases = spec["paramAliases"]
      named = !args.empty? && !args[0]["name"].nil?
      # Deprecated aliases resolve exactly as upstream's resolveParamAliases:
      # an alias present without its canonical name migrates the value; with
      # both present the canonical name wins; the alias is always consumed.
      # Only named arguments participate, matching upstream's kwarg-only
      # resolution.
      canonical_supplied = {}
      alias_warned = {}
      if named && aliases
        args.each do |arg|
          next if arg["name"].nil? || arg["value"].nil? || arg["value"].equal?(UNSUPPORTED_INPUT)

          canonical_supplied[arg["name"]] = true
        end
      end
      params = {}
      surfaces = {}
      provided = {}
      args.each_with_index do |arg, index|
        supplied =
          if named
            arg["name"]
          elsif index < param_names.length
            param_names[index]
          end
        # A deprecated alias records its canonical name (upstream's post-
        # resolution `seen` set does the same for explicit params).
        name = named && aliases ? (aliases[supplied] || supplied) : supplied
        if name.nil? || name == "" || !param_specs.key?(name)
          bad = (!supplied.nil? && supplied != "") ? supplied : "argument #{index + 1}"
          _throw("Unknown parameter \"#{bad}\" for #{effect_id}; accepted: #{param_names.join(', ')}", arg["loc"])
        end
        next if arg["value"].equal?(UNSUPPORTED_INPUT)

        if named && supplied != name
          # An alias argument migrates its value to the canonical name unless
          # that name was also supplied directly; the canonical name wins.
          # Every alias hit warns, as upstream's S007 diagnostic does.
          if !arg["value"].nil? && !alias_warned.key?(supplied)
            alias_warned[supplied] = true
            warn "param '#{supplied}' is deprecated, use '#{name}' instead. Aliases will be removed on 2027-06-01."
            unless canonical_supplied.key?(name)
              pspec = param_specs[name]
              if pspec.is_a?(Hash) && pspec["type"] == "surface"
                surfaces[name] = _surface_marker(arg["value"], name, arg["loc"])
              else
                params[name] = arg["value"]
              end
              provided[name] = true
            end
          end
          next
        end

        provided[name] = true
        pspec = param_specs[name]
        if pspec.is_a?(Hash) && pspec["type"] == "surface"
          marker = _surface_marker(arg["value"], name, arg["loc"])
          surfaces[name] = marker
        else
          params[name] = arg["value"]
        end
      end
      param_names.each do |name|
        pspec = param_specs[name]
        next unless pspec.is_a?(Hash) && pspec["type"] == "surface"
        next if provided[name] || !pspec.key?("default")

        marker = _surface_marker(pspec["default"], name, nil)
        surfaces[name] = marker unless marker.nil?
      end
      [params, surfaces]
    end

    # `read3d(vol, geo)` and `write3d(vol, geo)` take two positional references:
    # identifiers such as vol0 and geo0, or surface references (upstream parseWriteCall
    # and the validator's Read3D handling).
    def self._volume_references(call)
      return nil if call["argMode"] != "positional" || call["args"].length != 2

      names = call["args"].map do |arg|
        value = arg["value"]
        if value.is_a?(Hash) && value["kind"] == "surface"
          value["name"]
        elsif value.is_a?(Hash) && value["kind"] == "identifier" && !value["name"].include?(".")
          value["name"]
        end
      end
      names.include?(nil) ? nil : names
    end

    def self._read3d_references(call)
      if call["argMode"] == "named"
        named = call["args"].each_with_object({}) { |arg, map| map[arg["name"]] = arg }
        return nil unless named.key?("tex3d") && named.key?("geo")

        return _volume_references("argMode" => "positional", "args" => [named["tex3d"], named["geo"]])
      end
      _volume_references(call)
    end

    # Compiles one chain. A statement chain that begins with a generator must end with
    # write(oN). A chain argument (`inline`) needs no write(): its last image is the
    # argument's surface.
    def self._compile_chain(chain, bindings, inline: false)
      search = bindings.search
      effects = bindings.registry
      steps = []
      has_image = false
      has_volume = false
      starts_with_generator = false
      open_loop = nil
      # A subchain block contributes its body calls in place. Upstream's validator
      # wraps them in `_subchain_begin`/`_subchain_end` markers, which its expander
      # passes through without a render pass.
      calls = chain["calls"].flat_map { |element| element["kind"] == "Subchain" ? element["body"] : [element] }
      calls.each_with_index do |raw_call, index|
        call = raw_call
        binding = bindings[call["name"]]
        if binding && binding["kind"] == "alias"
          call = call.merge("name" => binding["name"])
        elsif binding
          _throw("Binding \"#{call['name']}\" is not callable", call["loc"]) unless binding["kind"] == "partial"

          call = _merge_partial(binding["call"], call)
        end
        # Chain arguments compile while the arguments resolve; they belong to this call.
        outer_pending = bindings.pending
        bindings.pending = []
        begin
          args = _resolve_args(call["args"], bindings)
        ensure
          inline_chains = bindings.pending
          bindings.pending = outer_pending
        end
        if call["name"] == "read"
          if index != 0 || args.length != 1 || !_is_surface(args[0]["value"])
            _throw("read(surface) must begin a chain", call["loc"])
          end
          steps << { "kind" => "read", "surface" => args[0]["value"]["name"], "loc" => call["loc"] }
          has_image = true
          next
        end
        if call["name"] == "write"
          _throw("loopBegin must be closed by loopEnd before write", call["loc"]) if open_loop
          if !has_image || args.length != 1 || !_is_surface(args[0]["value"])
            _throw("write(surface) requires a current image", call["loc"])
          end
          steps << { "kind" => "write", "surface" => args[0]["value"]["name"], "loc" => call["loc"] }
          next
        end
        # Built-in volume I/O (upstream `_write3d` and `_read3d`). write3d stores the
        # current volume and geometry under the two names and passes the chain through;
        # read3d starts a chain from them. A mid-chain read3d() is not a starter, so it
        # fails below as an unknown effect, as a one-argument read3d() at a chain start
        # does.
        if call["name"] == "write3d"
          # Upstream's lexer reserves write3d, so it cannot start a chain.
          _throw("Expected effect or IO function name", call["loc"]) if index == 0
          _throw("loopBegin must be closed by loopEnd before write", call["loc"]) if open_loop
          references = _volume_references(call)
          _throw("Expected surface reference", call["loc"]) unless references
          steps << { "kind" => "write3d", "volume" => references[0], "geometry" => references[1],
                     "loc" => call["loc"] }
          next
        end
        if index == 0 && call["name"] == "read3d" && (references = _read3d_references(call))
          steps << { "kind" => "read3d", "volume" => references[0], "geometry" => references[1],
                     "loc" => call["loc"] }
          has_volume = true
          next
        end
        namespaces = call["namespace"] ? [call["namespace"]] : search
        effect_id = _resolve_effect(call["name"], namespaces, effects)
        if effect_id.nil?
          _throw("Unknown effect \"#{call['name']}\" in search namespaces #{namespaces.join(', ')}", call["loc"])
        end
        spec = effects[effect_id]
        domain = spec["domain"] || "image"
        if domain == "volume-generator"
          if index != 0 && !(spec["iterated"] && has_volume)
            _throw("Generator #{effect_id} must begin a chain", call["loc"])
          end
          starts_with_generator = true if index == 0
          has_volume = true
        elsif domain == "volume-filter"
          _throw("volume filter #{effect_id} requires a volume input", call["loc"]) unless has_volume
        elsif domain == "volume-renderer"
          _throw("volume renderer #{effect_id} requires a volume input", call["loc"]) unless has_volume
          has_image = true
        elsif domain == "loop-begin"
          _throw("#{effect_id} requires a current image", call["loc"]) unless has_image
          _throw("nested loopBegin regions are not supported", call["loc"]) if open_loop
          open_loop = call["loc"]
        elsif domain == "loop-end"
          _throw("loopEnd has no matching loopBegin", call["loc"]) unless open_loop
          _throw("#{effect_id} requires a current image", call["loc"]) unless has_image
          open_loop = nil
        elsif spec["kind"] == "generator"
          _throw("Generator #{effect_id} must begin a chain", call["loc"]) if index != 0

          starts_with_generator = true
          has_image = true
        elsif !has_image
          requires_input_tex = (spec["passes"] || []).any? do |p|
            (p["inputs"] || {}).values.any? { |v| v == "inputTex" }
          end
          if requires_input_tex
            _throw("#{spec['kind']} #{effect_id} requires an input; begin with a generator or read(oN)",
                   call["loc"])
          end
          has_image = true
        end
        params, surfaces = _normalize_effect(effect_id, spec, args)
        step = {
          "kind" => "effect",
          "effect_id" => effect_id,
          "params" => params,
          "surfaces" => surfaces,
          "loc" => call["loc"],
        }
        step["inline_chains"] = inline_chains unless inline_chains.empty?
        steps << step
      end
      _throw("loopBegin must be closed by loopEnd before the chain ends", open_loop) if open_loop
      terminal = steps.empty? ? nil : steps[-1]["kind"]
      if !inline && starts_with_generator && terminal != "write" && terminal != "write3d"
        _throw("Generator chain must end with write(oN)", chain["loc"])
      end
      { "steps" => steps, "loc" => chain["loc"] }
    end

    def self.compile_dsl(source, effects, options = nil)
      options = {} unless options.is_a?(Hash)
      ast = parse_dsl(source, options)
      _throw("Missing required search directive", ast["loc"]) if ast["search"].empty?

      bindings = Scope.new(effects, ast["search"])
      next_binding = 0
      declare_binding = lambda do |binding|
        value = binding["value"]
        if value.is_a?(Hash) && value["kind"] == "Call" && !VALUE_CALLS.include?(value["name"])
          # A partial keeps its call unresolved. Its arguments resolve where it is
          # called, as upstream's validator substitutes a symbol at each use.
          bindings[binding["name"]] = { "kind" => "partial", "call" => value }
        elsif (alias_result = _alias_binding(value, bindings))
          bindings[binding["name"]] = alias_result
        else
          # A bare identifier value must name something resolvable now (an
          # earlier binding, an alias, or an effect), as upstream's declareVar
          # requires.
          if value.is_a?(Hash) && value["kind"] == "identifier" && !value["name"].include?(".") &&
             !bindings.key?(value["name"]) && _resolve_effect(value["name"], bindings.search, bindings.registry).nil?
            _throw("Variable used before assignment: '#{value['name']}'", value["loc"])
          end
          bindings[binding["name"]] = {
            "kind" => "value", "expr" => value, "resolved" => false, "value" => nil,
          }
        end
      end
      # Statement order (upstream 9cc041d0): a chain sees only the lets declared
      # at or before its own statement index; a later `let` of the same name
      # reassigns it for later statements; reading a pending name reports S003.
      declare_through = lambda do |chain_index|
        while next_binding < ast["bindings"].length &&
              (ast["bindings"][next_binding]["planIndex"] || 0) <= chain_index
          declare_binding.call(ast["bindings"][next_binding])
          next_binding += 1
        end
      end

      chains = ast["chains"].map.with_index do |chain, chain_index|
        declare_through.call(chain_index)
        # pendingNames covers the whole chain compile, including inline chains:
        # every argument position reports a pending read, as upstream does.
        bindings.pending_names = ast["bindings"].slice(next_binding..).map { |b| b["name"] }.to_set
        begin
          _compile_chain(chain, bindings)
        ensure
          bindings.pending_names = nil
        end
      end
      declare_through.call(Float::INFINITY)

      last_written = nil
      chains.each do |chain|
        chain["steps"].each do |step|
          last_written = step["surface"] if step["kind"] == "write"
        end
      end
      render_surface = ast["render"] ? ast["render"]["name"] : last_written
      if render_surface.nil?
        _throw("No render surface specified and no write() found - add render(oN) or write(oN)", ast["loc"])
      end

      { "search" => ast["search"].dup, "chains" => chains, "render_surface" => render_surface }
    end

    # Upstream `let x = noise` makes `x` an alias of the effect function, and
    # `let y = x` copies a partial or an alias (the validator stores the symbol's
    # expression and substitutes it where `y` is used).
    def self._alias_binding(value, bindings)
      return nil unless value.is_a?(Hash) && value["kind"] == "identifier" && !value["name"].include?(".")

      bound = bindings[value["name"]]
      if bound
        return bound if bound["kind"] == "partial" || bound["kind"] == "alias"

        return nil
      end
      _resolve_effect(value["name"], bindings.search, bindings.registry) ? { "kind" => "alias", "name" => value["name"] } : nil
    end

    # ---- diagnostic error object ----

    # Exception raised by every tokenizer/parser/compiler diagnostic -- port
    # of dsl/error.py DslError (a SyntaxError subclass in Python; here a
    # StandardError subclass so plain `rescue => e` in cli.rb catches it --
    # Ruby's SyntaxError descends from ScriptError, not StandardError, so
    # subclassing it would make ordinary rescue clauses silently miss DSL
    # errors). #message is "<sourceName>:<line>:<column>: <message>\n",
    # matching the Perl port's stringified die text (and Python's
    # SyntaxError text) including the trailing newline.
    class Error < StandardError
      attr_reader :source_name, :line, :column

      def initialize(message, location = nil)
        location = {} unless location.is_a?(Hash)
        @source_name = location["sourceName"] || "<dsl>"
        @line = location["line"] || 1
        @column = location["column"] || 1
        super("#{@source_name}:#{@line}:#{@column}: #{message}\n")
      end
    end
  end
end
