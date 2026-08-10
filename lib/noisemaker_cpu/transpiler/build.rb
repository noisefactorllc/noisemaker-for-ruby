# frozen_string_literal: true

# Regenerate the vendored Ruby kernel bundle from the CDN.
#
# Pipeline: CDN.fetch_effect -> Preprocess.normalize -> Parser.parse ->
# Codegen.emit_ruby -> write lib/noisemaker_cpu/bundle/. Pure Ruby.
#
#   ruby -Ilib -r noisemaker_cpu/transpiler/build -e 'NoisemakerCpu::Transpiler::Build.run(*ARGV)' -- --all
#   (or scripts/build-bundle.rb [--all | --only a,b] [--update-lock])
#
# NOTE (integration dependency): normalize/parse/emit_ruby come from Worker
# B's transpiler/{preprocess,parser,codegen}.rb and SHARED_ENUMS from
# transpiler/shared_enums.rb -- written here against those CONTRACTED module
# and method names (docs/2026-08-08-ruby-port-contract.md's file map), same
# as Perl's Build.pm calls its Transpiler siblings 1:1. Those files are not
# this worker's to create; `build`/`run` cannot execute until they land.

require "digest/sha2"
require "json"
require "fileutils"

require_relative "cdn"
require_relative "preprocess"
require_relative "parser"
require_relative "codegen"
require_relative "shared_enums"

module NoisemakerCpu
  module Transpiler
    module Build
      SCATTER_ADAPTER_KEYS = %w[
        points/dla:depositGrid points/lenia:deposit points/physarum:deposit
        render/pointsRender:deposit render/pointsBillboardRender:deposit
      ].each_with_object({}) { |key, out| out[key] = true }.freeze

      def self.bundle_dir
        here = __dir__ # .../noisemaker_cpu/transpiler
        File.expand_path(File.join(here, "..", "bundle"))
      end

      # Inline choices for member params that reference a shared enum by name
      # only (the CDN bundle omits the name->index table). Mutates params in
      # place (params.values holds references to the same nested Hash
      # objects stored in params, so mutating a spec mutates the original).
      def self._resolve_shared_enums(params)
        params.values.each do |spec|
          next unless spec.is_a?(Hash)
          next unless (spec["type"] || "") == "member" && !spec["choices"]

          choices = NoisemakerCpu::Transpiler::SharedEnums::SHARED_ENUMS[spec["enum"] || ""]
          spec["choices"] = choices.dup if choices
        end
      end

      def self.runtime_defines(params)
        out = {}
        params.values.each do |spec|
          next unless spec.is_a?(Hash) && !spec["define"].nil?

          out[spec["define"]] = ((spec["type"] || "") == "float") ? "float" : "int"
        end
        out
      end

      def self.infer_kind(effect_id, passes)
        namespace = effect_id.split("/", 2).first
        return "generator" if namespace == "synth"
        return "mixer" if namespace == "mixer"

        passes.each do |p|
          return "filter" if p["inputs"] && !p["inputs"].empty?
        end
        "generator"
      end

      def self._key(eid, program)
        "#{eid}:#{program}"
      end

      def self._file(key)
        "#{key.gsub(%r{[/:]}, "__")}.rb"
      end

      def self._read_json(path)
        text =
          begin
            File.binread(path)
          rescue SystemCallError
            return nil
          end
        JSON.parse(text)
      end

      def self._write_raw(path, text)
        FileUtils.mkdir_p(File.dirname(path))
        begin
          File.binwrite(path, text)
        rescue SystemCallError => e
          raise "cannot write #{path}: #{e.message}\n"
        end
      end

      def self._adapt_source(effect_id, program, source)
        if effect_id == "filter/temporalAberration" && program == "temporalAberration"
          return source.gsub(
            /slots\[(\d+)\]\s*=\s*\(s\.a\s*<\s*0\.5\)\s*\?\s*cur\s*:\s*s\s*;/,
            'if (s.a >= 0.5) { slots[\1] = s; }'
          )
        end
        return source unless effect_id == "synth/navierStokes" && program == "nsSplat"

        source.gsub(
          "p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));",
          "p.x = dot(p, vec2(127.1, 311.7)); p.y = dot(p, vec2(269.5, 183.3));"
        )
      end

      def self.build(ids, out_dir: nil, update_lock: false)
        out_dir ||= bundle_dir
        kdir = File.join(out_dir, "kernels", "ruby")
        FileUtils.mkdir_p(kdir)
        lock_path = File.join(out_dir, "bundle-lock.json")
        old = _read_json(lock_path) || { "hashes" => {} }
        hashes = (old["hashes"] || {}).dup
        drift = []
        bundle = {
          "provenance" => {
            "source" => "shaders.noisedeck.app CDN",
            "version" => NoisemakerCpu::Transpiler::CDN::CDN_VERSION,
            "base" => NoisemakerCpu::Transpiler::CDN::CDN_BASE,
          },
          "effects" => {},
        }
        n_ok = 0
        n_skip = 0
        ids.each do |eid|
          eff =
            begin
              NoisemakerCpu::Transpiler::CDN.fetch_effect(eid)
            rescue StandardError => e
              n_skip += 1
              first_line = e.message.to_s.split("\n", 2).first || ""
              warn "skip #{eid}: cdn: #{first_line[0, 70]}"
              nil
            end
          next unless eff

          _resolve_shared_enums(eff["params"])
          defines = runtime_defines(eff["params"])
          passes = []
          eff["passes"].each do |p|
            key = _key(eid, p["program"])
            glsl = eff["programs"][p["program"]]
            if glsl.nil? || SCATTER_ADAPTER_KEYS.key?(key)
              # A pass without GLSL is a CPU-only draw op (e.g. wormhole's
              # point-scatter deposit). Keep it so the renderer can run its
              # native adapter; it has no transpiled kernel key.
              if p["drawMode"]
                pass_record = {
                  "name" => p["name"],
                  "program" => p["program"],
                  "key" => nil,
                  "inputs" => (p["inputs"] || {}),
                  "outputs" => (p["outputs"] || {}),
                  "uniforms" => (p["uniforms"] || {}),
                }
                %w[repeat blend clear drawMode count countUniform type entryPoint drawBuffers conditions].each do |field|
                  pass_record[field] = p[field] unless p[field].nil?
                end
                passes << pass_record
              end
              next
            end
            stripped = glsl.strip
            h = Digest::SHA256.hexdigest(stripped)
            ruby_src =
              begin
                adapted = _adapt_source(eid, p["program"], glsl)
                norm = NoisemakerCpu::Transpiler::Preprocess.normalize(adapted, defines)
                ast = NoisemakerCpu::Transpiler::Parser.parse(norm["source"])
                NoisemakerCpu::Transpiler::Codegen.emit_ruby(ast, norm["outputs"], norm["varyings"])
              rescue StandardError => e
                n_skip += 1
                first_line = e.message.to_s.split("\n", 2).first || ""
                warn "skip #{key}: #{first_line[0, 80]}"
                nil
              end
            next if ruby_src.nil?

            _write_raw(File.join(kdir, _file(key)), ruby_src)
            drift << key if old["hashes"] && old["hashes"][key] && old["hashes"][key] != h
            hashes[key] = h
            n_ok += 1
            pass_record = {
              "name" => p["name"],
              "program" => p["program"],
              "key" => key,
              "inputs" => (p["inputs"] || {}),
              "outputs" => (p["outputs"] || {}),
              "uniforms" => (p["uniforms"] || {}),
            }
            %w[repeat blend clear drawMode count countUniform type entryPoint drawBuffers conditions].each do |field|
              pass_record[field] = p[field] unless p[field].nil?
            end
            passes << pass_record
          end
          next if passes.empty?

          bundle["effects"][eid] = {
            "namespace" => (eff["namespace"] || eid.split("/", 2).first),
            "func" => eff["func"],
            "kind" => infer_kind(eid, eff["passes"]),
            "params" => eff["params"],
            # Definition order of params -- the oracle binds positional DSL
            # args and mixer surface feeds by this order; Hash key order
            # would work here too (Ruby preserves it) but we mirror perl's
            # explicit fallback rather than relying on that incidentally.
            "paramOrder" => (eff["paramOrder"] || eff["params"].keys.sort),
            "textures" => (eff["textures"] || {}),
            "passes" => passes,
          }
          bundle["effects"][eid]["externalTexture"] = eff["externalTexture"] if eff["externalTexture"]
          bundle["effects"][eid]["iterated"] = true if eff["iterated"]
          %w[outputXyz outputVel outputRgba].each do |field|
            bundle["effects"][eid][field] = eff[field] unless eff[field].nil?
          end
        end
        if !drift.empty? && !update_lock
          shown = drift[0, [drift.length, 8].min]
          warn "\nSHADER DRIFT vs bundle-lock.json (#{drift.length}): #{shown.join(", ")}\nRe-run with --update-lock to accept.\n"
          exit(1)
        end
        _write_raw(File.join(out_dir, "metadata.json"), JSON.pretty_generate(bundle))
        _write_raw(
          lock_path,
          JSON.pretty_generate(
            {
              "source" => NoisemakerCpu::Transpiler::CDN::CDN_BASE,
              "version" => NoisemakerCpu::Transpiler::CDN::CDN_VERSION,
              "hashes" => hashes,
            }
          )
        )
        puts "wrote #{bundle["effects"].keys.length} effect(s) (#{n_ok} programs, #{n_skip} skipped) " \
             "from CDN #{NoisemakerCpu::Transpiler::CDN::CDN_VERSION}"
      end

      def self.run(*argv)
        argv = ARGV if argv.empty?
        ids =
          if argv.include?("--all")
            NoisemakerCpu::Transpiler::CDN.eligible_ids
          elsif (i = argv.index("--only"))
            if i >= argv.length - 1 || argv[i + 1].start_with?("--")
              raise "--only requires a comma-separated effect-id list\n"
            end
            argv[i + 1].split(",")
          else
            ["synth/solid", "filter/invert"]
          end
        build(ids, update_lock: argv.include?("--update-lock"))
      end
    end
  end
end
