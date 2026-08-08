# frozen_string_literal: true

# GLSL ES 3.00 tokenizer (post-preprocess).
#
# Consumes already-normalized/preprocessed GLSL (no #directives). Produces a
# flat token list for the recursive-descent parser. Tokens are Hashes:
# { "kind" => "num"|"id"|"op", "value" => str, "pos" => int }.

module NoisemakerCpu
  module Transpiler
    module Lexer
      # Multi-char operators, longest first so the scanner is greedy.
      OPS = [
        "<<=", ">>=",
        "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
        "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "|", "^",
        "?", ":", ".", ",", ";", "(", ")", "[", "]", "{", "}",
      ].freeze

      # \G anchors the match to the explicit `pos` given to Regexp#match (NOT
      # a plain forward search like Ruby's default `match(str, pos)` would
      # do) -- the same exact-position semantics as Perl's `/\G.../gc`.
      NUM = /\G(?:
          0[xX][0-9a-fA-F]+                 # hex int
        | (?:\d+\.\d*|\.\d+|\d+)            # decimal, with optional fraction
          (?:[eE][+-]?\d+)?                 # optional exponent
        )
        [uUfF]?                             # optional type suffix
      /x.freeze

      WS = /\G\s+/.freeze
      LINE_COMMENT = %r{\G//[^\n]*}.freeze
      BLOCK_COMMENT = %r{\G/\*.*?\*/}m.freeze
      IDENT = /\G[A-Za-z_][A-Za-z0-9_]*/.freeze

      def self.tokenize(source)
        tokens = []
        i = 0
        n = source.length
        while i < n
          if (m = WS.match(source, i))
            i = m.end(0)
            next
          end
          if (m = LINE_COMMENT.match(source, i))
            i = m.end(0)
            next
          end
          if source[i, 2] == "/*"
            m = BLOCK_COMMENT.match(source, i)
            raise "unterminated block comment at #{i}\n" unless m

            i = m.end(0)
            next
          end
          c = source[i]
          if c =~ /[0-9]/ || (c == "." && source[i + 1] =~ /[0-9]/)
            m = NUM.match(source, i)
            raise "bad number at #{i}\n" unless m

            tokens << { "kind" => "num", "value" => m[0], "pos" => i }
            i = m.end(0)
            next
          end
          if c =~ /[A-Za-z_]/
            m = IDENT.match(source, i)
            tokens << { "kind" => "id", "value" => m[0], "pos" => i }
            i = m.end(0)
            next
          end
          matched = false
          OPS.each do |op|
            next unless source[i, op.length] == op

            tokens << { "kind" => "op", "value" => op, "pos" => i }
            i += op.length
            matched = true
            break
          end
          raise "unexpected character '#{c}' at #{i}\n" unless matched
        end
        tokens << { "kind" => "op", "value" => "<eof>", "pos" => n }
        tokens
      end
    end
  end
end
