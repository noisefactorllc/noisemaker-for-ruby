# frozen_string_literal: true

# Per-pixel pass runner -- turns a compiled kernel into filled Surface data.
#
# Faithful port of noisemaker-cpu src/runtime/pass-runner.js. GLSL uses a
# BOTTOM-LEFT origin with pixel centers at (x+0.5, y+0.5); surface storage is
# top-down. So for top-down row y we feed the kernel fy = height-y-0.5
# (bottom-left) and uv = fragCoord / resolution. The kernel writes 4 floats
# into out; we store them into the top-down row.

# NOTE (parallel-build bootstrap): Surface and Runtime are owned by Worker A
# and may not exist yet while this file is authored. Neither run_pass nor
# run_pass_deriv resolves NoisemakerCpu::Surface until actually CALLED (Ruby
# only looks up a bare constant when the method body executes), so this file
# -- including the Ctx class, which never touches Surface -- loads standalone
# even before surface.rb/runtime.rb land. Once they exist, these requires
# succeed normally and nothing else changes.
begin
  require_relative "surface"
rescue LoadError
  nil
end
begin
  require_relative "runtime"
rescue LoadError
  nil
end

module NoisemakerCpu
  module PassRunner
    def self._f32(x)
      [x].pack("e").unpack1("e")
    end
  end

  # Per-render context handed to each kernel invocation. rt/uniforms/textures/
  # resolution/time/seed are set once per pass; frag_coord/uv per pixel.
  class Ctx
    attr_reader :rt, :uniforms, :textures, :time, :seed
    attr_accessor :frag_coord, :uv, :resolution

    def initialize(rt: nil, uniforms: nil, textures: nil, resolution: nil, time: nil, seed: nil, blank: nil)
      @rt = rt
      @uniforms = uniforms.nil? ? {} : uniforms
      @textures = textures.nil? ? {} : textures
      @resolution = resolution
      @time = NoisemakerCpu::PassRunner._f32(time.nil? ? 0.0 : time)
      @seed = seed.nil? ? 1 : seed
      @blank = blank # 1x1 blank surface for unbound samplers
      @frag_coord = nil
      @uv = nil
    end

    # Sampler lookup with the WebGL unbound-sampler default: a missing binding
    # reads as a 1x1 black surface (the Python port's _DefaultTex).
    def texture_binding(name)
      t = @textures[name]
      t.nil? ? @blank : t
    end
  end

  module PassRunner
    def self.run_pass(kernel, ctx, width, height)
      surf = NoisemakerCpu::Surface.new(width, height)
      data = surf.data
      out = [0.0, 0.0, 0.0, 0.0]
      fw = 0.0 + width
      fh = 0.0 + height
      ctx.resolution = [fw, fh] if ctx.resolution.nil?
      (0..height - 1).each do |y|
        fy = height - y - 0.5
        base = y * width * 4
        (0..width - 1).each do |x|
          fx = x + 0.5
          ctx.frag_coord = [fx, fy, 0.0, 1.0]
          ctx.uv = [_f32(fx.fdiv(fw)), _f32(fy.fdiv(fh))]
          kernel.call(ctx, out)
          i = base + x * 4
          data[i, 4] = out
        end
      end
      surf
    end

    def self.run_pass_mrt(kernel, ctx, width, height, destination_count)
      surfaces = Array.new(destination_count) { NoisemakerCpu::Surface.new(width, height) }
      out = Array.new(destination_count * 4, 0.0)
      fw = 0.0 + width
      fh = 0.0 + height
      ctx.resolution = [fw, fh] if ctx.resolution.nil?
      (0..height - 1).each do |y|
        fy = height - y - 0.5
        base = y * width * 4
        (0..width - 1).each do |x|
          fx = x + 0.5
          ctx.frag_coord = [fx, fy, 0.0, 1.0]
          ctx.uv = [_f32(fx.fdiv(fw)), _f32(fy.fdiv(fh))]
          kernel.call(ctx, out)
          destination_index = base + x * 4
          surfaces.each_index do |chunk|
            output_index = chunk * 4
            surfaces[chunk].data[destination_index, 4] = out[output_index, 4]
          end
        end
      end
      surfaces
    end

    # Pass runner for kernels using dFdx/dFdy/fwidth. Mirrors the reference
    # engine's wrapDerivatives: derivatives are computed in bottom-left pixel
    # space over 2x2 quads. Each quad's 4 corners are probed in 'record' mode
    # (arguments captured, no edge clamping -- probes may fall outside the
    # image like the GPU); each real pixel then replays with FINE derivatives
    # selected by its parity.
    def self.run_pass_deriv(kernel, ctx, width, height)
      surf = NoisemakerCpu::Surface.new(width, height)
      data = surf.data
      rt = ctx.rt
      fw = 0.0 + width
      fh = 0.0 + height
      ctx.resolution = [fw, fh] if ctx.resolution.nil?

      set_frag = lambda do |fx, fy|
        ctx.frag_coord = [fx, fy, 0.0, 1.0]
        ctx.uv = [_f32(fx.fdiv(fw)), _f32(fy.fdiv(fh))]
      end
      probe = lambda do |fx, fy|
        set_frag.call(fx, fy)
        rt.deriv_reset("record")
        kernel.call(ctx, [0.0, 0.0, 0.0, 0.0])
        rt.deriv_log
      end

      lane_cache = {}
      diff_cache = {}
      (0..height - 1).each do |y|
        fy = height - y - 0.5
        (0..width - 1).each do |x|
          fx = x + 0.5
          pixel_x = x
          pixel_y = height - 1 - y # bottom-left pixel row
          quad_x = pixel_x >> 1
          quad_y = pixel_y >> 1
          qkey = "#{quad_x},#{quad_y}"
          lanes = lane_cache[qkey]
          if !lanes
            x0 = quad_x * 2 + 0.5
            y0 = quad_y * 2 + 0.5
            lanes = [
              probe.call(x0, y0),
              probe.call(x0 + 1, y0),
              probe.call(x0, y0 + 1),
              probe.call(x0 + 1, y0 + 1)
            ]
            lane_cache[qkey] = lanes
          end
          xp = pixel_x & 1
          yp = pixel_y & 1
          dkey = "#{qkey},#{xp},#{yp}"
          diffs = diff_cache[dkey]
          if !diffs
            diffs = rt.deriv_fine(lanes, xp, yp)
            diff_cache[dkey] = diffs
          end
          set_frag.call(fx, fy)
          rt.deriv_reset("replay", diffs)
          out = [0.0, 0.0, 0.0, 0.0]
          kernel.call(ctx, out)
          i = (y * width + x) * 4
          data[i, 4] = out
        end
      end
      rt.deriv_reset(nil)
      surf
    end
  end
end
