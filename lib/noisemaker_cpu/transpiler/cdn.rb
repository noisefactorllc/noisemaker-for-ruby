# frozen_string_literal: true

# Fetch shader source + effect metadata from the shaders.noisedeck.app CDN.
#
# The CDN serves a per-effect ESM bundle at /<version>/effects/<id>.js that
# inlines both the effect definition (globals == params, passes, textures)
# and the raw GLSL (shaders[program].glsl). Pure Ruby, no JS execution: we
# extract the pieces from the bundle TEXT (template-literal scan for GLSL,
# balanced-delimiter walk + JSON5-shaped literal reading for the definition).
#
# Fetches are cached to disk as EXTRACTED JSON (never raw .js) under
# .cdn-cache/<version>/, so repeat runs are offline after the first hit --
# and the cache can be seeded from the (byte-identical) Python port's cache.
#
# HTTPS: Ruby's stdlib net/http (with OpenSSL) does the fetching -- this is
# the one file in the port allowed to touch the network (see the port
# contract's Worker rules). Perl's CDN.pm falls back to shelling out to curl
# when HTTP::Tiny lacks SSL support; net/http's SSL support is part of the
# Ruby stdlib build we target, so there is no equivalent fallback here.

require "json"
require "net/http"
require "uri"
require "fileutils"

require_relative "computed_defs"

module NoisemakerCpu
  module Transpiler
    module CDN
      CDN_BASE = (ENV["NM_SHADER_CDN"] || "https://shaders.noisedeck.app").sub(%r{/+\z}, "")
      # The "1.0" minor channel is the current release (rolling tag).
      CDN_VERSION = ENV["NM_SHADER_VERSION"] || "1.0"

      NAMESPACE_EXCLUSIONS = %w[filter3d synth3d].each_with_object({}) { |k, h| h[k] = true }.freeze
      RENDER_ALLOWLIST = %w[pointsEmit pointsRender pointsBillboardRender]
                         .each_with_object({}) { |k, h| h[k] = true }.freeze
      ID_EXCLUSIONS = %w[
        synth/roll synth/scope synth/spectrum
        classicNoisedeck/noise3d classicNoisedeck/shapes3d
      ].each_with_object({}) { |k, h| h[k] = true }.freeze
      ITERATED_IDS = %w[
        filter/convolutionFeedback filter/feedback filter/motionBlur filter/temporalAberration
        points/attractor points/buddhabrot points/dla points/flock points/flow points/hydraulic
        points/lenia points/life points/physarum points/physical
        render/pointsBillboardRender render/pointsEmit render/pointsRender
        synth/cellularAutomata synth/mnca synth/navierStokes synth/reactionDiffusion
      ].each_with_object({}) { |k, h| h[k] = true }.freeze

      # <dist>/.cdn-cache, next to lib/ (three levels up from
      # lib/noisemaker_cpu/transpiler/cdn.rb -- perl's CDN.pm goes up five
      # because Math/Fractal/Noisemaker/Transpiler is a deeper directory
      # nesting than noisemaker_cpu/transpiler; the destination -- repo
      # root's .cdn-cache -- is the same).
      def self.cache_root
        File.expand_path(File.join(__dir__, "..", "..", "..", ".cdn-cache"))
      end

      def self._cache_dir(version)
        safe = version.gsub(/[^\w.-]/, "_")
        File.join(cache_root, safe)
      end

      def self._fetch_text(url)
        uri = URI.parse(url)
        response =
          begin
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 30) do |http|
              request = Net::HTTP::Get.new(uri)
              request["User-Agent"] = "noisemaker-for-ruby transpiler (+https://noisedeck.app)"
              http.request(request)
            end
          rescue StandardError => e
            raise "CDN request failed for #{url}: #{e.message}\n"
          end
        raise "CDN #{response.code} #{response.message} for #{url}\n" unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s.dup.force_encoding("UTF-8")
      end

      def self._read_file(path)
        File.binread(path)
      end

      def self._write_file(path, text)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, text)
      end

      def self.fetch_manifest(version = nil)
        version ||= CDN_VERSION
        cache = File.join(_cache_dir(version), "effects", "manifest.json")
        return JSON.parse(_read_file(cache)) if File.exist?(cache)

        text = _fetch_text("#{CDN_BASE}/#{version}/effects/manifest.json")
        _write_file(cache, text)
        JSON.parse(text)
      end

      # ---- bundle text extraction ----

      # text[i] is a quote char (', ", or `); return index just past the close.
      def self._skip_string(text, i)
        quote = text[i]
        n = text.length
        i += 1
        while i < n
          c = text[i]
          if c == "\\"
            i += 2
            next
          end
          return i + 1 if c == quote

          i += 1
        end
        i # unterminated -- treat end-of-text as the boundary
      end

      # Balanced {...}/[...] substring starting at start; strings skipped whole.
      def self._extract_balanced(text, start)
        c0 = text[start]
        raise "expected '{' or '[' at offset #{start}\n" unless c0 == "{" || c0 == "["

        depth = 0
        i = start
        n = text.length
        while i < n
          c = text[i]
          if c == '"' || c == "'" || c == "`"
            i = _skip_string(text, i)
            next
          end
          if c == "{" || c == "["
            depth += 1
          elsif c == "}" || c == "]"
            depth -= 1
            return text[start, i + 1 - start] if depth == 0
          end
          i += 1
        end
        raise "unbalanced brackets: reached end of text\n"
      end

      # Rewrite minifier boolean shorthand (!0 / !1 -> true / false) outside strings.
      def self._normalize_js_literals(text)
        out = []
        i = 0
        n = text.length
        while i < n
          c = text[i]
          if c == '"' || c == "'" || c == "`"
            start = i
            i = _skip_string(text, i)
            out << text[start, i - start]
            next
          end
          two = text[i, 2]
          if two == "!0" || two == "!1"
            prev = i > 0 ? text[i - 1, 1] : ""
            nxt = i + 2 < n ? text[i + 2, 1] : ""
            if prev !~ /[\w$]/ && nxt !~ /[\w$]/
              out << (two == "!0" ? "true" : "false")
              i += 2
              next
            end
          end
          out << c
          i += 1
        end
        out.join
      end

      # Replace value-position bare identifiers with 0 (UI-metadata fields may
      # reference minified module-scope constants). Keys and true/false/null kept.
      #
      # DELIBERATE DEVIATION FROM PERL: this had the identical exponent-marker
      # bug as _json5_decode's old identifier branch (see that method's
      # DELIBERATE DEVIATION comment for the full corruption story) --
      # `e`/`E` immediately after digits was misidentified as a standalone
      # bare identifier VALUE and replaced with "0". This function runs
      # BEFORE _json5_decode (only for the "globals" field), so fixing
      # _json5_decode's own number handling was NOT sufficient on its own:
      # by the time _json5_decode saw synth/newton's `min:1e-4`, this
      # function had already mangled it to `min:10-4` (a syntactically
      # broken token, hence newton's hard parse failure), and had already
      # silently mangled synth/julia's `max:1e3`, classicNoisedeck/coalesce's
      # `hueAB:1e3`, and synth/osc2d's `max:1e3` to `10` apiece -- confirmed
      # by generating a full bundle and diffing it against perl's committed
      # metadata.json. Perl's Transpiler/CDN.pm has the identical gap and
      # would corrupt/fail identically against this live content. Fix:
      # recognize (and pass through byte-for-byte, via the same
      # _scan_json5_number used by _json5_decode) a number literal wherever
      # one can start, before ever considering the bare-identifier branch --
      # numbers are never "value-position bare identifiers" needing
      # sanitization, only genuine JS-computed-constant references are.
      def self._sanitize_bare_identifiers(text)
        out = []
        i = 0
        n = text.length
        while i < n
          c = text[i]
          if c == '"' || c == "'" || c == "`"
            start = i
            i = _skip_string(text, i)
            out << text[start, i - start]
            next
          end
          if c =~ /[-+.0-9]/
            scanned = _scan_json5_number(text, i)
            if scanned
              normalized, new_i = scanned
              out << normalized
              i = new_i
              next
            end
          end
          if c =~ /[A-Za-z_$]/
            j = i
            j += 1 while j < n && text[j] =~ /[A-Za-z0-9_$]/
            ident = text[i, j - i]
            k = j
            k += 1 while k < n && text[k] =~ /[ \t\n\r]/
            is_key = k < n && text[k] == ":"
            out << ((is_key || ident == "true" || ident == "false" || ident == "null") ? ident : "0")
            i = j
            next
          end
          out << c
          i += 1
        end
        out.join
      end

      # Locate key's value: object-literal `key: value` or class-field `"key", value`.
      def self._find_value_start(text, key)
        k = Regexp.escape(key)
        m = text.match(/(?:\b#{k}\b\s*:|["']#{k}["']\s*,)\s*/)
        m ? m.end(0) : nil
      end

      # Scan one JS/JSON5 number literal starting at text[i]: optional sign,
      # integer part, optional fraction (`.` + digits -- including a
      # leading dot with no integer part), optional exponent (`e`/`E`,
      # optional sign, digits). Returns [normalized_text, end_index] if a
      # number starts at i, or nil if it doesn't (no digits at all, e.g. a
      # bare "-" or "." not followed by a digit). A leading-dot number gets
      # the implied "0" (`.5` -> `0.5`, `-.5` -> `-0.5`); a leading unary
      # "+" is dropped (`+5` -> `5`, matching perl's old plus-sign special
      # case); everything else -- the integer part, the fraction, and the
      # WHOLE exponent including its own sign -- passes through unchanged,
      # since strict JSON's number grammar already accepts it.
      def self._scan_json5_number(text, i)
        n = text.length
        pos = i
        sign = ""
        if text[pos] == "-"
          sign = "-"
          pos += 1
        elsif text[pos] == "+"
          pos += 1 # explicit leading plus -- dropped, not part of strict JSON
        end

        int_start = pos
        pos += 1 while pos < n && text[pos] =~ /\d/
        int_part = text[int_start...pos]

        frac_part = ""
        if pos < n && text[pos] == "." && pos + 1 < n && text[pos + 1] =~ /\d/
          frac_start = pos
          pos += 1
          pos += 1 while pos < n && text[pos] =~ /\d/
          frac_part = text[frac_start...pos]
        end

        return nil if int_part.empty? && frac_part.empty? # no digits anywhere -- not a number

        exp_part = ""
        if pos < n && (text[pos] == "e" || text[pos] == "E")
          exp_start = pos
          exp_pos = pos + 1
          exp_pos += 1 if exp_pos < n && (text[exp_pos] == "+" || text[exp_pos] == "-")
          digit_start = exp_pos
          exp_pos += 1 while exp_pos < n && text[exp_pos] =~ /\d/
          if exp_pos > digit_start # at least one exponent digit -- a real exponent, consume it
            exp_part = text[exp_start...exp_pos]
            pos = exp_pos
          end
          # else: bare trailing "e"/"E" with no digits after it isn't a
          # valid exponent -- leave pos where it was and let the "e" itself
          # be handled by whatever comes next in the walk (the identifier
          # branch above, same as any other bareword).
        end

        int_part = "0" if int_part.empty? # leading-dot form: `.5` -> `0.5`
        [sign + int_part + frac_part + exp_part, pos]
      end

      # Convert a JSON5-shaped literal (unquoted keys, single quotes, trailing
      # commas) to strict JSON, then decode.
      def self._json5_decode(text)
        out = []
        i = 0
        n = text.length
        while i < n
          c = text[i]
          if c == "'" || c == "`" # single/backtick string -> double-quoted
            end_idx = _skip_string(text, i)
            body = text[i + 1, end_idx - i - 2]
            body = body.gsub(/\\(['`])/) { Regexp.last_match(1) } # unescape original quotes
            body = body.gsub(/(["\\])/) { "\\" + Regexp.last_match(1) } # escape for JSON
            body = body.gsub("\n") { "\\n" }
            body = body.gsub("\t") { "\\t" }
            body = body.gsub("\r") { "\\r" }
            out << ('"' + body + '"')
            i = end_idx
            next
          end
          if c == '"'
            end_idx = _skip_string(text, i)
            out << text[i, end_idx - i]
            i = end_idx
            next
          end
          if c =~ /[A-Za-z_$]/ # bare identifier: quote keys, keep literals
            j = i
            j += 1 while j < n && text[j] =~ /[A-Za-z0-9_$]/
            ident = text[i, j - i]
            k = j
            k += 1 while k < n && text[k] =~ /[ \t\n\r]/
            is_key = k < n && text[k] == ":"
            if is_key
              out << ('"' + ident + '"')
            elsif ident == "true" || ident == "false" || ident == "null"
              out << ident
            elsif ident == "undefined"
              out << "null"
            elsif ident == "Infinity"
              out << "1e308"
            elsif ident == "NaN"
              out << "0"
            else
              out << "0" # sanitized elsewhere; belt+braces
            end
            i = j
            next
          end
          # JSON5 relaxations handled IN the walk, so string contents (already
          # emitted whole above) can never be corrupted by them:
          if c == "," # trailing comma before } or ] -- drop it
            k = i + 1
            k += 1 while k < n && text[k] =~ /[ \t\n\r]/
            if k < n && (text[k] == "}" || text[k] == "]")
              i += 1
              next
            end
          end
          # DELIBERATE DEVIATION FROM PERL: Transpiler/CDN.pm's _json5_decode
          # has no number-literal handling at all (its only special cases
          # before this point are string/identifier/comma; a lone leading
          # "+" before a digit was dropped and everything else, including
          # digits, fell through to verbatim copy). That is not just a
          # leading-dot gap: JS's bare-leading-dot decimal shorthand (`.5`
          # for `0.5`) reaches JSON::PP / JSON.parse as invalid strict JSON,
          # AND -- discovered only by diffing a full generated
          # metadata.json against perl's committed one, not by the earlier
          # per-effect empirical survey -- falling through per-character
          # let the identifier branch above misidentify an exponent marker
          # (`e`/`E` immediately after digits, as in `1e3`) as a bare
          # identifier VALUE and silently replace it with "0", corrupting
          # `1e3` to `10`, `2E+4` to `204`, `-1e3` to `-10`, and leaving
          # `1.5e-7` with a dangling, unparseable "-7". This corrupted real
          # committed values (classicNoisedeck/coalesce hueAB 1000->10,
          # synth/julia iterations.max 1000->10, synth/osc2d seed.max
          # 1000->10) and broke synth/newton's parse outright (its globals
          # use negative-exponent constants). Perl's own CDN.pm has the
          # identical gap and would corrupt/fail identically against this
          # live content -- it only ever looked correct off a python-seeded
          # warm cache that no longer exists. The scaffold's standing rule
          # is durable, reproducible builds, so a cold fetch must succeed
          # AND be correct on its own; Python's `json5` library -- a real
          # JSON5 parser, and the reference for what this CDN content means
          # -- already handles the full number grammar correctly.
          #
          # Fix: scan a whole JS/JSON5 number literal as one token (see
          # _scan_json5_number) wherever one can start (digit, sign, or
          # leading dot), rather than processing digit/sign/dot/exponent
          # characters individually through the generic per-character
          # branches above. Leading-dot forms get the implied "0"; every
          # other numeric form (plain integers, `-1e3`, `1.5e-7`, `2E+4`,
          # explicit unary `+` dropped as before) passes through UNCHANGED,
          # since strict JSON already accepts standard exponent notation --
          # this is not "no innovation" scope creep, it is fixing the
          # PARSE, not changing what any value means.
          if c =~ /[-+.0-9]/
            scanned = _scan_json5_number(text, i)
            if scanned
              normalized, new_i = scanned
              out << normalized
              i = new_i
              next
            end
          end
          out << c
          i += 1
        end
        JSON.parse(out.join)
      end

      # Read the single JS value (string/object/array literal) at start.
      def self._read_literal(text, start, sanitize = false)
        return nil if start.nil? || start >= text.length

        c = text[start]
        if c == "{" || c == "["
          raw = _normalize_js_literals(_extract_balanced(text, start))
          raw = _sanitize_bare_identifiers(raw) if sanitize
          return _json5_decode(raw)
        end
        if c == '"' || c == "'"
          end_idx = _skip_string(text, start)
          return _json5_decode(text[start, end_idx - start])
        end
        nil
      end

      # Slice the bundle down to the definition region (before the shaders object).
      def self._definition_region(bundle)
        m = bundle.match(/(\w+)\s*:\s*\{\s*glsl\s*:\s*`/)
        m ? bundle[0, m.begin(0)] : bundle
      end

      # Extract every program's GLSL template literal.
      def self._extract_programs(bundle)
        programs = {}
        re = /(\w+)\s*:\s*\{\s*glsl\s*:\s*`/
        pos = 0
        while (m = re.match(bundle, pos))
          program = m[1]
          backtick_start = m.end(0) - 1
          end_idx = _skip_string(bundle, backtick_start)
          programs[program] = bundle[backtick_start + 1, end_idx - 1 - (backtick_start + 1)]
          pos = end_idx
        end
        programs
      end

      def self._parse_field(region, effect_id, key, default)
        start = _find_value_start(region, key)
        return default if start.nil?

        value =
          begin
            _read_literal(region, start, key == "globals")
          rescue StandardError => e
            raise "CDN effect '#{effect_id}': could not parse '#{key}' as a JSON5 literal " \
                  "(likely a JS-computed definition -- see ComputedDefs): #{e.message}\n"
          end
        value.nil? ? default : value
      end

      # Top-level key order of a JSON object's text -- JSON.parse loses nothing
      # in Ruby (Hash preserves insertion order), but this mirrors perl's
      # explicit raw-text key scan 1:1 since paramOrder is captured this way
      # for CACHED documents too (see fetch_effect) where the source is a
      # canonical (rewritten) JSON text, not the original bundle.
      #
      # DELIBERATE DEVIATION FROM PERL: Transpiler/CDN.pm's own
      # ordered_object_keys only recognizes QUOTED string keys, so run
      # against RAW bundle text -- where object keys are bareword/unquoted
      # in the common minified-JS style, e.g. `{mode:{type:"int",...}}` --
      # it always returns []. Confirmed identical in perl's actual CDN.pm
      # live in this session. It only ever looked right because perl's
      # development history cold-built once against a python-seeded warm
      # cache: a fresh fetch bakes the empty paramOrder into its own cache
      # write, and only the *next* fetch self-heals (fetch_effect's
      # cache-hit branch below re-derives it via params_key_order against
      # that now-quoted JSON text, where the identical bareword gap doesn't
      # apply). That seed cache no longer exists, and the scaffold calls for
      # durable, reproducible builds, so a genuinely cold fetch must derive
      # the same paramOrder a warm one does -- this recognizes bareword
      # identifier keys too, using the same identifier grammar
      # (`[A-Za-z_$][A-Za-z0-9_$]*`) already used elsewhere in this file.
      def self.ordered_object_keys(text)
        keys = []
        i = text.index("{")
        return keys if i.nil?

        n = text.length
        depth = 0
        while i < n
          c = text[i]
          if c == '"' || c == "'"
            end_idx = _skip_string(text, i)
            if depth == 1
              body = text[i + 1, end_idx - i - 2]
              k = end_idx
              k += 1 while k < n && text[k] =~ /\s/
              keys << body if k < n && text[k] == ":"
            end
            i = end_idx
            next
          end
          if c =~ /[A-Za-z_$]/
            j = i
            j += 1 while j < n && text[j] =~ /[A-Za-z0-9_$]/
            if depth == 1
              k = j
              k += 1 while k < n && text[k] =~ /\s/
              keys << text[i, j - i] if k < n && text[k] == ":"
            end
            i = j
            next
          end
          if c == "{" || c == "["
            depth += 1
          elsif c == "}" || c == "]"
            depth -= 1
            return keys if depth == 0
          end
          i += 1
        end
        keys
      end

      # Key order of the "params" object inside a cached-effect JSON document.
      def self.params_key_order(doc_text)
        m = doc_text.match(/"params"\s*:\s*/)
        return [] unless m

        ordered_object_keys(_extract_balanced(doc_text, m.end(0)))
      end

      def self.fetch_effect(effect_id, version = nil)
        version ||= CDN_VERSION
        # Cache the EXTRACTED data as JSON (no raw CDN .js ever hits disk).
        cache = File.join(_cache_dir(version), "effects", "#{effect_id}.json")
        if File.exist?(cache)
          text = _read_file(cache)
          result = JSON.parse(text)
          unless result["paramOrder"] && !result["paramOrder"].empty?
            result["paramOrder"] = params_key_order(text)
          end
          _add_cpu_iteration_metadata(effect_id, result)
          return result
        end

        bundle = _fetch_text("#{CDN_BASE}/#{version}/effects/#{effect_id}.js")
        region = _definition_region(bundle)
        override = NoisemakerCpu::Transpiler::ComputedDefs::COMPUTED_DEFS[effect_id]
        result =
          if override
            {
              "id" => effect_id,
              "namespace" => override["namespace"],
              "func" => override["func"],
              "params" => override["params"],
              "paramOrder" => override["paramOrder"],
              "passes" => override["passes"],
              "textures" => (override["textures"] || {}),
              "externalTexture" => override["externalTexture"],
              "programs" => _extract_programs(bundle),
            }
          else
            param_order = []
            gstart = _find_value_start(region, "globals")
            param_order = ordered_object_keys(_extract_balanced(region, gstart)) if gstart && region[gstart] == "{"
            {
              "id" => effect_id,
              "namespace" => _parse_field(region, effect_id, "namespace", nil),
              "func" => _parse_field(region, effect_id, "func", nil),
              "params" => _parse_field(region, effect_id, "globals", {}),
              "paramOrder" => param_order,
              "passes" => _parse_field(region, effect_id, "passes", []),
              "textures" => _parse_field(region, effect_id, "textures", {}),
              "externalTexture" => _parse_field(region, effect_id, "externalTexture", nil),
              "outputXyz" => _parse_field(region, effect_id, "outputXyz", nil),
              "outputVel" => _parse_field(region, effect_id, "outputVel", nil),
              "outputRgba" => _parse_field(region, effect_id, "outputRgba", nil),
              "programs" => _extract_programs(bundle),
            }
          end
        _add_cpu_iteration_metadata(effect_id, result)
        # The cache is written as JSON, so paramOrder is stored explicitly --
        # a raw-text key scan on re-read would see whatever order JSON.parse
        # happened to preserve, not necessarily the CDN bundle's own order.
        _write_file(cache, JSON.generate(result))
        result
      end

      def self._add_cpu_iteration_metadata(effect_id, result)
        return result unless ITERATED_IDS.key?(effect_id)

        result["iterated"] = true
        result["params"]["iterationCount"] ||= {
          "type" => "int",
          "default" => 60,
          "min" => 0,
          "max" => 10_000,
          "cpuOnly" => true,
        }
        result["paramOrder"] ||= result["params"].keys
        result["paramOrder"] << "iterationCount" unless result["paramOrder"].include?("iterationCount")
        if effect_id == "render/pointsEmit" || effect_id.start_with?("points/")
          result["outputXyz"] ||= "global_xyz"
          result["outputVel"] ||= "global_vel"
          result["outputRgba"] ||= "global_rgba"
        end
        result
      end

      def self.eligible_ids(version = nil)
        manifest = fetch_manifest(version)
        result = []
        manifest.keys.sort.each do |effect_id|
          namespace = effect_id.split("/", 2).first
          next if NAMESPACE_EXCLUSIONS.key?(namespace)
          next if namespace == "render" && !RENDER_ALLOWLIST.key?(effect_id.split("/", 2)[1])
          next if effect_id.include?("3d") || effect_id.include?("cubemap") || effect_id.include?("mesh")
          next if ID_EXCLUSIONS.key?(effect_id)

          result << effect_id
        end
        result
      end
    end
  end
end
