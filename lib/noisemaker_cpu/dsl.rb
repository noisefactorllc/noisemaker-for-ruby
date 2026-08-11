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

module NoisemakerCpu
  module DSL
    KEYWORDS = %w[search let render true false].each_with_object({}) { |k, h| h[k] = true }.freeze
    PUNCTUATION = "()[],.:=;".each_char.each_with_object({}) { |c, h| h[c] = true }.freeze
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

      def check(lexeme)
        peek["lexeme"] == lexeme
      end

      def match(*lexemes)
        return false unless lexemes.include?(peek["lexeme"])

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
            ast["bindings"] << parse_binding(previous)
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
        calls << parse_call while match(".")
        { "kind" => "Chain", "calls" => calls, "loc" => first["loc"] }
      end

      def parse_call
        name = identifier("Expected effect or IO function name")
        consume("(")
        args = []
        mode = nil
        unless check(")")
          loop do
            is_named = peek["type"] == "identifier" && peek(1)["lexeme"] == ":"
            next_mode = is_named ? "named" : "positional"
            if mode && mode != next_mode
              DSL._throw("Cannot mix positional and named arguments", DSL._location(peek))
            end
            mode = next_mode
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
        { "kind" => "Call", "name" => name["lexeme"], "args" => args, "argMode" => mode, "loc" => DSL._location(name) }
      end

      def parse_value_expression(min_precedence = 0)
        left = parse_value_unary
        loop do
          lex = peek["lexeme"]
          prec = PRECEDENCE.key?(lex) ? PRECEDENCE[lex] : -1
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

    # Perl's Scalar::Util::looks_like_number, approximated: signed
    # int/float/exponent forms plus Inf/Infinity/NaN (any case), optional
    # surrounding whitespace.
    NUMBER_STRING_RE = /\A\s*[+-]?(?:\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|inf(?:inity)?|nan)\s*\z/i

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

    def self._evaluate_value(value, bindings)
      return value.map { |item| _evaluate_value(item, bindings) } if value.is_a?(Array)
      return value unless value.is_a?(Hash)

      kind = value["kind"] || ""
      case kind
      when "surface"
        value
      when "identifier"
        name = value["name"]
        if bindings.key?(name)
          binding = bindings[name]
          if binding["kind"] == "partial"
            _throw("Effect partial \"#{name}\" cannot be used as a value", value["loc"])
          end
          binding["value"]
        else
          name
        end
      when "vector"
        components = value["values"].map { |item| _evaluate_value(item, bindings) }
        width = value["width"]
        if components.length != width || components.any? { |c| !_is_number(c) }
          _throw("vec#{width} requires #{width} numeric values", value["loc"])
        end
        components
      when "unary"
        operand = _evaluate_value(value["argument"], bindings)
        _throw("Unary arithmetic requires a number", value["loc"]) unless _is_number(operand)
        # Perl's unary '+' is a passthrough (does not force numeric
        # conversion); only '-' does, via negation. Preserve that asymmetry.
        value["operator"] == "-" ? -_to_number(operand) : operand
      when "binary"
        left = _evaluate_value(value["left"], bindings)
        right = _evaluate_value(value["right"], bindings)
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

    def self._merge_partial(stored, call)
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

    # Map a call's arguments onto the effect's params, splitting value
    # params (handed to render_effect) from surface bindings. Like the
    # Python port (and unlike JS normalizeArguments) this does NOT validate
    # value type/range/enum-membership here; render_effect's _coerce
    # performs the coercion and fills defaults, so malformed values render
    # leniently while unknown parameter NAMES are still rejected.
    # paramOrder stands in for Python's list(param_specs.keys()) (see
    # module header).
    def self._normalize_effect(effect_id, spec, args)
      param_specs = spec["params"]
      param_names = spec["paramOrder"]
      named = !args.empty? && !args[0]["name"].nil?
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
        if supplied.nil? || supplied == "" || !param_specs.key?(supplied)
          bad = (!supplied.nil? && supplied != "") ? supplied : "argument #{index + 1}"
          _throw("Unknown parameter \"#{bad}\" for #{effect_id}; accepted: #{param_names.join(', ')}", arg["loc"])
        end
        provided[supplied] = true
        pspec = param_specs[supplied]
        if pspec.is_a?(Hash) && pspec["type"] == "surface"
          marker = _surface_marker(arg["value"], supplied, arg["loc"])
          surfaces[supplied] = marker unless marker.nil?
        else
          params[supplied] = arg["value"]
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

    def self._compile_chain(chain, bindings, search, effects)
      steps = []
      has_image = false
      has_volume = false
      starts_with_generator = false
      open_loop = nil
      chain["calls"].each_with_index do |raw_call, index|
        call = raw_call
        binding = bindings[call["name"]]
        if binding
          _throw("Binding \"#{call['name']}\" is not callable", call["loc"]) unless binding["kind"] == "partial"

          call = _merge_partial(binding["call"], call)
        end
        args = _resolve_args(call["args"], bindings)
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
        effect_id = _resolve_effect(call["name"], search, effects)
        if effect_id.nil?
          _throw("Unknown effect \"#{call['name']}\" in search namespaces #{search.join(', ')}", call["loc"])
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
        steps << {
          "kind" => "effect",
          "effect_id" => effect_id,
          "params" => params,
          "surfaces" => surfaces,
          "loc" => call["loc"],
        }
      end
      _throw("loopBegin must be closed by loopEnd before the chain ends", open_loop) if open_loop
      if starts_with_generator && (steps.empty? || steps[-1]["kind"] != "write")
        _throw("Generator chain must end with write(oN)", chain["loc"])
      end
      { "steps" => steps, "loc" => chain["loc"] }
    end

    def self.compile_dsl(source, effects, options = nil)
      options = {} unless options.is_a?(Hash)
      ast = parse_dsl(source, options)
      _throw("Missing required search directive", ast["loc"]) if ast["search"].empty?

      bindings = {}
      ast["bindings"].each do |binding|
        _throw("Duplicate binding \"#{binding['name']}\"", binding["loc"]) if bindings.key?(binding["name"])

        value = binding["value"]
        bindings[binding["name"]] =
          if value.is_a?(Hash) && value["kind"] == "Call"
            { "kind" => "partial", "call" => value.merge("args" => _resolve_args(value["args"], bindings)) }
          else
            { "kind" => "value", "value" => _evaluate_value(value, bindings) }
          end
      end

      chains = ast["chains"].map { |chain| _compile_chain(chain, bindings, ast["search"], effects) }

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
