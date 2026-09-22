# frozen_string_literal: true

# Regenerate the vendored Ruby kernel bundle from the CDN.
#
# Pipeline: CDN.fetch_effect -> Preprocess.normalize -> Parser.parse ->
# Codegen.emit_ruby -> write lib/noisemaker_cpu/bundle/. Pure Ruby.
#
#   ruby -Ilib -r noisemaker_cpu/transpiler/build -e 'NoisemakerCpu::Transpiler::Build.run(*ARGV)' -- --all
#   (or scripts/build-bundle.rb [--all | --only a,b] [--update-lock])
#
require "digest/sha2"
require "json"
require "fileutils"
require "tmpdir"
require_relative "../kernel_cache"

require_relative "cdn"
require_relative "preprocess"
require_relative "parser"
require_relative "codegen"
require_relative "shared_enums"

module NoisemakerCpu
  module Transpiler
    module Build
      SCATTER_ADAPTER_KEYS = %w[
        filter3d/flow3d:deposit
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
        return "generator" if namespace == "synth" || namespace == "synth3d"
        return "filter" if namespace == "filter3d"
        return "mixer" if namespace == "mixer"

        passes.each do |p|
          return "filter" if p["inputs"] && !p["inputs"].empty?
        end
        "generator"
      end

      def self.infer_domain(effect_id)
        namespace = effect_id.split("/", 2).first
        return "loop-begin" if effect_id == "render/loopBegin"
        return "loop-end" if effect_id == "render/loopEnd"
        return "volume-generator" if namespace == "synth3d"
        return "volume-filter" if namespace == "filter3d"
        return "volume-renderer" if effect_id.start_with?("render/render")

        "image"
      end

      def self.pass_outputs(pass)
        (pass["outputs"] || {}).to_h do |name, texture|
          [(pass["drawBuffers"].to_i >= 2 && name == "color") ? "fragColor" : name, texture]
        end
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
          rescue Errno::ENOENT
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
        # Match canonical CPU float32 hash and pigment storage boundaries.
        if %w[filter/mosaicTiles filter/stipple filter/strokes].include?(effect_id)
          source = source.gsub(
            "return fract((p3.x + p3.y) * p3.z);",
            "return fract(float(float(p3.x + p3.y) * p3.z));"
          ).gsub(
            "return fract((p3.xx + p3.yz) * p3.zy);",
            "return fract(vec2(float(float(p3.x + p3.y) * p3.z), float(float(p3.x + p3.z) * p3.y)));"
          )
        end
        if effect_id == "filter/strokes" && program == "stkSmear"
          pigment = "pigmentSum += srcSample(centerUV).rgb * mark;"
          raise "strokes canonical pigment pattern changed" unless source.scan(pigment).length == 1

          source = source.sub(pigment, "pigmentSum += vec3(srcSample(centerUV).rgb * mark);")
        end
        if effect_id.start_with?("synth3d/")
          source = source.gsub(
            /\bint\s+(z|vz)\s*=\s*([A-Za-z_]\w*(?:\.y)?)\s*\/\s*([A-Za-z_]\w*)\s*;/,
            'float \1 = float(\2) / float(\3);'
          )
        end
        if effect_id == "synth3d/cell3d" && program == "precompute"
          adapted = source.sub(
            "return vec3(q) / 4294967295.0;",
            "return cpu_cell3d_hash_result(q);"
          )
          raise "cannot locate synth3d/cell3d hash result for CPU lowering\n" if adapted == source

          return adapted.sub(
            /vec3\s+([A-Za-z_]\w*)\s*=\s*(neighbor\s*\+\s*mix\(vec3\(0\.5\),\s*randomOffset,\s*jitter\))\s*;\s*vec3\s+diff\s*=\s*\1\s*-\s*f\s*;/,
            'vec3 diff = \2 - f;'
          )
        end
        if effect_id == "synth3d/flythrough3d" && program == "precompute"
          return source
            .sub(/struct FractalResult \{.*?^\};\n/m, "")
            .gsub(/\bFractalResult\b/, "vec3")
            .gsub(/\.dist\b/, ".x")
            .gsub(/\.trap\b/, ".y")
            .gsub(/\.iterRatio\b/, ".z")
        end
        if effect_id == "synth3d/noise3d" && program == "precompute"
          adapted = source.sub(
            /\bfloat\s+hash4\s*\(\s*vec4\s+p\s*\)\s*\{.*?^\s*\}/m,
            "float hash4(vec4 p) {\n    return cpu_noise3d_hash4(p, seed);\n}"
          )
          raise "cannot locate synth3d/noise3d hash4 for CPU lowering\n" if adapted == source

          return adapted
        end
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

      # Construct and validate a complete bundle before touching the installed one.
      # Keep the old directory until the replacement has been installed successfully.
      def self.build(ids, out_dir: nil, update_lock: false)
        raise ArgumentError, "select at least one effect" if ids.empty?

        out_dir = File.expand_path(out_dir || bundle_dir)
        FileUtils.mkdir_p(File.dirname(out_dir))
        work = Dir.mktmpdir(".noisemaker-build-", File.dirname(out_dir))
        preserve_backup = false
        begin
          staged = File.join(work, "bundle")
          old = _read_json(File.join(out_dir, "bundle-lock.json")) || { "hashes" => {} }
          build_staged(ids, staged, old, update_lock)
          backup = File.join(work, "previous")
          begin
            File.rename(out_dir, backup) if File.exist?(out_dir)
            File.rename(staged, out_dir)
          # Recover even on Interrupt/SystemExit; never swallow the original
          # exception after restoring the previous bundle.
          rescue Exception => install_error
            begin
              File.rename(backup, out_dir) if File.exist?(backup)
            rescue Exception => restore_error
              preserve_backup = true
              raise "bundle installation failed: #{install_error.message}; restoration failed: " \
                    "#{restore_error.message}. Previous bundle preserved at #{backup}"
            end
            raise install_error
          end
        ensure
          # An asynchronous interruption can occur between any two Ruby
          # statements, including inside recovery. Keep the only copy.
          preserve_backup = true if backup && File.exist?(backup) && !File.exist?(out_dir)
          FileUtils.remove_entry(work) unless preserve_backup
        end
      end

      def self.build_staged(ids, out_dir, old, update_lock)
        kdir = File.join(out_dir, "kernels", "ruby")
        FileUtils.mkdir_p(kdir)
        lock_path = File.join(out_dir, "bundle-lock.json")
        hashes = {}
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
              raise "cannot build #{eid}: #{e.message}"
            end
          raise "missing effect definition for #{eid}" unless eff.is_a?(Hash)

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
                  "outputs" => pass_outputs(p),
                  "uniforms" => (p["uniforms"] || {}),
                }
                %w[repeat blend clear drawMode count countUniform type entryPoint drawBuffers conditions viewport].each do |field|
                  pass_record[field] = p[field] unless p[field].nil?
                end
                passes << pass_record
              else
                raise "missing shader source for #{key}"
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
                raise "cannot compile #{key}: #{e.message}"
              end
            NoisemakerCpu::KernelCache.load_kernel(ruby_src, key)

            _write_raw(File.join(kdir, _file(key)), ruby_src)
            drift << key if old["hashes"] && old["hashes"][key] && old["hashes"][key] != h
            hashes[key] = h
            n_ok += 1
            pass_record = {
              "name" => p["name"],
              "program" => p["program"],
              "key" => key,
              "inputs" => (p["inputs"] || {}),
              "outputs" => pass_outputs(p),
              "uniforms" => (p["uniforms"] || {}),
            }
            %w[repeat blend clear drawMode count countUniform type entryPoint drawBuffers conditions viewport].each do |field|
              pass_record[field] = p[field] unless p[field].nil?
            end
            passes << pass_record
          end
          raise "no renderable passes for #{eid}" if passes.empty?

          bundle["effects"][eid] = {
            "namespace" => (eff["namespace"] || eid.split("/", 2).first),
            "func" => eff["func"],
            "kind" => infer_kind(eid, eff["passes"]),
            "domain" => infer_domain(eid),
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
          bundle["effects"][eid]["loopRole"] = "begin" if eid == "render/loopBegin"
          bundle["effects"][eid]["loopRole"] = "end" if eid == "render/loopEnd"
          %w[outputTex outputTex3d outputGeo outputXyz outputVel outputRgba].each do |field|
            bundle["effects"][eid][field] = eff[field] unless eff[field].nil?
          end
        end
        if !drift.empty? && !update_lock
          shown = drift[0, [drift.length, 8].min]
          raise "SHADER DRIFT vs bundle-lock.json (#{drift.length}): #{shown.join(', ')}. " \
                "Re-run with --update-lock to accept."
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

      private_class_method :build_staged

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
