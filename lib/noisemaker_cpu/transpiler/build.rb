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
        # The generator's preserveVectorAssignmentReads (compile-glsl.js
        # ~199-207) rewrites ONLY single-line `target = vecN(...)` statements
        # whose expression references `target.`: `vec2 temp = expr; target =
        # temp;` (a snapshot). Multi-line constructors (mandelbrot's
        # `dz = vec2(\n ..., ...);`) do NOT match and lower to the JS
        # comma-assign where later components read the ALREADY-STORED earlier
        # components (dz.y reads the new dz.x).
        vtemp_n = 0
        source = source.gsub(
          /^([ \t]*)([A-Za-z_]\w*)\s*=\s*((?:[biu]?vec[234])\s*\([^;\n]*\))[ \t]*;$/m
        ) do
          full = Regexp.last_match(0)
          indent = Regexp.last_match(1)
          target = Regexp.last_match(2)
          expr_src = Regexp.last_match(3)
          type = expr_src.match(/^([biu]?vec[234])\s*\(/)&.[](1)
          if type && expr_src.match?(/\b#{Regexp.escape(target)}\.[xyzwrgba]\b/)
            vtemp_n += 1
            temp = "cpu_vector_assignment_#{vtemp_n}"
            "#{indent}#{type} #{temp} = #{expr_src};\n#{indent}#{target} = #{temp};"
          else
            full
          end
        end
        # The generator's CPU lowering (compile-glsl.js) replaces ANY user
        # `uvec3 pcg|pcg3|pcg3d(uvec3 ...)` function with a direct
        # stdlib.pcg3d call: the GLSL body's per-component uint ops would
        # otherwise run as raw scalars (spatter's hashf produced 1e18-scale
        # values instead of [0,1]). Warp stays byte-identical either way
        # (its vector uint ops already wrap).
        %w[pcg pcg3 pcg3d].each do |fname|
          source = source.gsub(
            /uvec3\s+#{fname}\s*\(\s*uvec3\s+\w+\s*\)\s*\{[^}]*\}/m,
            "uvec3 #{fname}(uvec3 value) { return pcg3d(value); }"
          )
        end
        # Match canonical CPU float32 hash and pigment storage boundaries.
        # The oracle's adaptCanonicalSource applies the float32 hash
        # boundary patch to EVERY effect except filter/scatter; restricting
        # it to a hand-picked list left craquelure's hash12/hash22 with
        # deferred-f64 rounding (2-ulp hash drift).
        if effect_id != "filter/scatter"
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
        if effect_id == "synth/curl"
          # The oracle's adaptCanonicalSource rewrites this line so the
          # whole-vector reassign decomposes into per-component scalar tanh
          # calls (stdlib.tanh = unary(Math.tanh)) instead of a
          # scalar-OP-vector raw operator (NaN for width>1).
          adapted = source.sub(
            "curl = tanh(curl * intensity) * 0.5 + 0.5;",
            "curl = vec3(tanh(curl.x * intensity) * 0.5 + 0.5, " \
            "tanh(curl.y * intensity) * 0.5 + 0.5, tanh(curl.z * intensity) * 0.5 + 0.5);"
          )
          raise "cannot locate synth/curl tanh line for CPU lowering\n" if adapted == source

          source = adapted
        end
        if effect_id == "synth/polygon"
          # The oracle's adaptCanonicalSource special-cases smoothing == 0
          # (smoothstep with equal edges is a division by zero): the m
          # test becomes a hard threshold.
          adapted = source.sub(
            "float m = smoothstep(radius, radius - smoothing, d);",
            "float m = smoothing == 0.0 ? (d <= radius ? 1.0 : 0.0) : smoothstep(radius, radius - smoothing, d);"
          )
          raise "cannot locate synth/polygon smoothstep line for CPU lowering\n" if adapted == source

          source = adapted
        end
        if effect_id == "filter/dither" && program == "dither"
          # The oracle's compiled kernel truncates the int cell/FS_BLOCK
          # division with |0 at the '/' (the canonical form is
          # `(cpu_float(cell[..]) / cpu_float(FS_BLOCK)|0) * FS_BLOCK|0`):
          # floor(7.5/2)=3 → 3/4|0 = 0, so blockOrigin is the block floor
          # (0), not the raw cell (3). The port's int '/' keeps the f64
          # quotient (testPattern's `temp /= 10` semantics), so reproduce
          # the truncation by rewriting the GLSL to an explicit int floor.
          adapted = source.sub(
            "ivec2 blockOrigin = (cell / FS_BLOCK) * FS_BLOCK;",
            "ivec2 blockOrigin = ivec2(int(floor(float(cell.x) / float(FS_BLOCK))), int(floor(float(cell.y) / float(FS_BLOCK)))) * FS_BLOCK;"
          )
          raise "cannot locate filter/dither blockOrigin for CPU lowering\n" if adapted == source

          source = adapted
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
          }.merge!(if NoisemakerCpu::Transpiler::CDN.glsl_root.nil?
                    {}
                  else
                    { "glslRoot" => NoisemakerCpu::Transpiler::CDN.glsl_root }
                  end),
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
                ruby_src = NoisemakerCpu::Transpiler::Codegen.emit_ruby(ast, norm["outputs"], norm["varyings"])
                # The upstream JS generator mis-compiles render3d's voxel
                # DDA (canonical-kernels.js 28046/28074/28075): the initial
                # `voxelToWorld(voxel + max(step, ivec3(0)))` unwinds to
                # `voxel[k] + max(step, cpu_ivec3(0))` — number + ivec3
                # ARRAY, JS string-concats then ToNumber → NaN for every
                # component — so tMaxVec starts all-NaN, the stepping chain
                # always takes the z-branch with tStart=NaN (NaN>x
                # comparisons false), and only initial-voxel solid tests
                # ever produce real hits (NaN dist hits fail `dist > 0`).
                # Mirror each component via scalar_vec_coerce (number +
                # int-array → NaN), which already implements the JS rule.
                if eid == "render/render3d" || eid == "render/renderCubemap3d"
                  q0 = "voxelBounds = rt.construct(3, voxelToWorld__ivec3.call(rt.binary('+', voxel, rt.component_wise('max', step, rt.construct(3, rt.i(0), 'int')), 3, 'int')))"
                  q1 = "voxel = rt.assign_swizzle(voxel, 'x', rt.binary('+', rt.swizzle(voxel, 'x'), rt.swizzle(step, 'x'), 1, 'int'))"
                  q2 = "lastNormal[0] = rt.f32(rt.unary('-', rt.construct(1, rt.swizzle(step, 'x'))))"
                  raise "render3d voxel-step quirk site not found in generated #{key}" unless ruby_src.include?(q0)

                  # voxelToWorld is pure, so emitting its NaN result directly
                  # (as floats) is value-exact and avoids the ruby IVec's
                  # ToInt32(NaN)=0, which the JS oracle's number-typed arrays
                  # never apply.
                  maxc = "rt.component_wise('max', step, rt.construct(3, rt.i(0), 'int'))"
                  ruby_src = ruby_src.gsub(q0, "voxelBounds = rt.construct(3, rt.scalar_vec_coerce('+', rt.swizzle(voxel, 'x'), #{maxc}, 1), rt.scalar_vec_coerce('+', rt.swizzle(voxel, 'y'), #{maxc}, 1), rt.scalar_vec_coerce('+', rt.swizzle(voxel, 'z'), #{maxc}, 1))")
                  # Dead in the oracle (both chain comparisons are
                  # NaN-vs-NaN → false), kept scalar-exact.
                  ruby_src = ruby_src.gsub(q1, "voxel = rt.assign_swizzle(voxel, 'x', rt.scalar_vec_coerce('+', rt.swizzle(voxel, 'x'), step, 1))") if ruby_src.include?(q1)
                  ruby_src = ruby_src.gsub(q2, "lastNormal[0] = rt.scalar_vec_coerce('-', rt.f(0), step, 1)") if ruby_src.include?(q2)
                end
                if eid == "render/pointsBillboardRender" && p["program"] == "blend"
                  # The oracle generator drops the assignment in
                  # `outRGB = outAlpha > 0.0 ? outRGB_pre / outAlpha : vec3(0.0);`
                  # (canonical-kernels.js 27406): the ternary is emitted as a
                  # bare statement — the true branch computes the divide into
                  # a discarded array, the false branch reduce-writes
                  # vec3(0) into outRGB. Net: outRGB stays [0,0,0] under
                  # blendMode 1.
                  qb = "outRGB.replace(((rt.bool(rt.binary('>', outAlpha, rt.f(0))) ? (rt.binary('/', outRGB_pre, outAlpha, 3, 'float')) : (rt.construct(3, rt.f(0))))).map { |c| rt.f32(c) })"
                  raise "pointsBillboardRender blend ternary site not found in generated #{key}" unless ruby_src.include?(qb)

                  ruby_src = ruby_src.gsub(qb, "if rt.bool(rt.binary('>', outAlpha, rt.f(0)))\n        rt.binary('/', outRGB_pre, outAlpha, 3, 'float')\n      else\n        outRGB.replace((rt.construct(3, rt.f(0))).map { |c| rt.f32(c) })\n      end")
                end
                if eid == "filter/dither" && p["program"] == "dither"
                  # The oracle's error-diffusion block stores back into the
                  # pooled errRow rows (PooledFloat32Array writes f32-round
                  # each component, canonical-kernels.js 10963-10968), while
                  # rightErr is a plain JS array produced by `.map` (raw f64
                  # stores, 10957/10966). The transpiler can't see pooled vs
                  # plain backing, so mirror the oracle's five stores
                  # explicitly: f32 per component for errRow, raw for
                  # rightErr. Without this the accumulated error drifts by
                  # ulps and errorDiffusion quantization flips (the pinned
                  # dither digest regresses).
                  d0 = "errRow[(i).to_i] = rt.binary('*', fsSeedNoise__ivec2_int.call(blockOrigin, i), stepScale, 3, 'float')"
                  raise "dither errRow seed store not found in generated #{key}" unless ruby_src.include?(d0)
                  ruby_src = ruby_src.gsub(d0, "errRow[(i).to_i] = (rt.binary('*', fsSeedNoise__ivec2_int.call(blockOrigin, i), stepScale, 3, 'float')).map { |c| rt.f32(c) }")
                  d1 = "rightErr = rt.construct(3, rt.binary('*', fsSeedNoise__ivec2_int.call(blockOrigin, rt.binary('+', rt.binary('+', g['FS_ERR_W'], g['FS_APRON_MAX'], 1, 'int'), r, 1, 'int')), stepScale, 3, 'float'))"
                  raise "dither rightErr init not found in generated #{key}" unless ruby_src.include?(d1)
                  ruby_src = ruby_src.gsub(d1, "rightErr = rt.binary('*', fsSeedNoise__ivec2_int.call(blockOrigin, rt.binary('+', rt.binary('+', g['FS_ERR_W'], g['FS_APRON_MAX'], 1, 'int'), r, 1, 'int')), stepScale, 3, 'float')")
                  d2 = "rightErr.replace((rt.binary('*', err, rt.f(0.4375), 3, 'float')).map { |c| rt.f32(c) })"
                  raise "dither rightErr store not found in generated #{key}" unless ruby_src.include?(d2)
                  ruby_src = ruby_src.gsub(d2, "rightErr.replace(rt.binary('*', err, rt.f(0.4375), 3, 'float'))")
                  d3 = "errRow[(rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int')).to_i] = rt.binary('+', errRow[(rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int')).to_i], rt.binary('*', err, rt.f(0.1875), 3, 'float'), 3, 'float')"
                  raise "dither errRow plus store not found in generated #{key}" unless ruby_src.include?(d3)
                  ruby_src = ruby_src.gsub(d3, "errRow[(rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int')).to_i] = (rt.binary('+', errRow[(rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int')).to_i], rt.binary('*', err, rt.f(0.1875), 3, 'float'), 3, 'float')).map { |c| rt.f32(c) }")
                  d4 = "errRow[(rt.binary('+', rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int'), rt.i(1), 1, 'int')).to_i] = rt.binary('+', diag, rt.binary('*', err, rt.f(0.3125), 3, 'float'), 3, 'float')"
                  raise "dither errRow diag store not found in generated #{key}" unless ruby_src.include?(d4)
                  ruby_src = ruby_src.gsub(d4, "errRow[(rt.binary('+', rt.binary('+', c, g['FS_APRON_MAX'], 1, 'int'), rt.i(1), 1, 'int')).to_i] = (rt.binary('+', diag, rt.binary('*', err, rt.f(0.3125), 3, 'float'), 3, 'float')).map { |c| rt.f32(c) }")
                end
                ruby_src
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
