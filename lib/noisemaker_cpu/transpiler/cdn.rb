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

      # Effects the transpiler does not target (3D, points, mesh/cubemap,
      # stateful and reactive effects) -- mirrors the Python port's exclusion
      # sets. Perl builds these as hashes-of-1 for O(1) membership; Ruby
      # mirrors that (a Hash used purely as a set) rather than a plain Array.
      NAMESPACE_EXCLUSIONS = %w[filter3d synth3d points render].each_with_object({}) { |k, h| h[k] = true }.freeze
      ID_EXCLUSIONS = %w[
        filter/convolutionFeedback filter/feedback filter/motionBlur
        filter/temporalAberration synth/cellularAutomata synth/mnca
        synth/navierStokes synth/reactionDiffusion synth/roll synth/scope
        synth/spectrum classicNoisedeck/noise3d classicNoisedeck/shapes3d
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
          if c == "+" && i + 1 < n && text[i + 1] =~ /\d/
            i += 1 # explicit plus sign on a number -- drop it
            next
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
              "programs" => _extract_programs(bundle),
            }
          end
        # The cache is written as JSON, so paramOrder is stored explicitly --
        # a raw-text key scan on re-read would see whatever order JSON.parse
        # happened to preserve, not necessarily the CDN bundle's own order.
        _write_file(cache, JSON.generate(result))
        result
      end

      def self.eligible_ids(version = nil)
        manifest = fetch_manifest(version)
        result = []
        manifest.keys.sort.each do |effect_id|
          namespace = effect_id.split("/", 2).first
          next if NAMESPACE_EXCLUSIONS.key?(namespace)
          next if effect_id.include?("3d") || effect_id.include?("cubemap") || effect_id.include?("mesh")
          next if ID_EXCLUSIONS.key?(effect_id)

          result << effect_id
        end
        result
      end
    end
  end
end
