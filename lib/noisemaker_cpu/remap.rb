# frozen_string_literal: true

require_relative "sampler"

module NoisemakerCpu
  # The CPU remap adapter operates on the authored vertices and bounds in double
  # precision. Zone overlap and feather distances are evaluated in canvas pixels.
  module Remap
    Zone = Struct.new(:vertices, :bounds, :alpha, :surface)

    def self.zones(ctx, width, height, feather)
      uniforms = ctx.uniforms
      count = uniforms.fetch("zoneCount", 0).to_i.clamp(0, 8)
      (count - 1).downto(0).filter_map do |index|
        prefix = "zone#{index}_"
        n = [uniforms.fetch("#{prefix}count", 0).to_i, 64].min
        next if n < 3 || uniforms.fetch("#{prefix}active", 0) < 0.5

        vertices = Array.new(n) do |i|
          pair = uniforms.fetch("#{prefix}v#{i / 2}", [0, 0, 0, 0])
          offset = (i % 2) * 2
          [pair[offset] * width, pair[offset + 1] * height]
        end
        x0, y0, x1, y1 = uniforms.fetch("#{prefix}bounds", [0, 0, 1, 1])
        dx, dy = feather.fdiv(width), feather.fdiv(height)
        Zone.new(vertices, [x0 - dx, y0 - dy, x1 + dx, y1 + dy],
                 uniforms.fetch("#{prefix}alpha", 1), ctx.texture_binding("#{prefix}tex"))
      end
    end

    def self.coverage(vertices, x, y, feather)
      inside = false
      distance2 = 1e30
      bx, by = vertices.last
      vertices.each do |ax, ay|
        ex, ey = bx - ax, by - ay
        wx, wy = x - ax, y - ay
        c1, c2, c3 = y >= ay, y < by, ex * wy > ey * wx
        inside = !inside if (c1 && c2 && c3) || !(c1 || c2 || c3)
        if feather > 0
          s = ((wx * ex + wy * ey).fdiv([ex * ex + ey * ey, 1e-6].max)).clamp(0, 1)
          rx, ry = wx - ex * s, wy - ey * s
          d2 = rx * rx + ry * ry
          distance2 = d2 if d2 < distance2
        end
        bx, by = ax, ay
      end
      return 1 if inside
      return 0 unless feather > 0

      t = Math.sqrt(distance2).fdiv(feather).clamp(0, 1)
      1 - t * t * (3 - 2 * t)
    end

    def self.kernel(rt, _compiled)
      previous_context = nil
      width = height = feather = offset_x = offset_y = nil
      active_zones = background = background_alpha = nil
      lambda do |ctx, out|
        rt.begin_pixel(ctx)
        unless ctx.equal?(previous_context)
          width, height = ctx.uniforms.fetch("fullResolution")
          offset_x, offset_y = ctx.uniforms.fetch("tileOffset", [0, 0])
          feather = [ctx.uniforms.fetch("smoothEdge", 0), 0].max * 0.05 * [width, height].min
          active_zones = zones(ctx, width, height, feather)
          background = ctx.uniforms.fetch("bgColor", [0, 0, 0])
          background_alpha = ctx.uniforms.fetch("bgAlpha", 1)
          previous_context = ctx
        end

        frag_x, frag_y = ctx.frag_coord
        x, y = frag_x + offset_x, height - (frag_y + offset_y)
        px, py = x.fdiv(width), y.fdiv(height)
        tile_width, tile_height = ctx.uniforms.fetch("resolution")
        u, v = frag_x.fdiv(tile_width), frag_y.fdiv(tile_height)
        r = g = b = a = 0.0
        active_zones.each do |zone|
          x0, y0, x1, y1 = zone.bounds
          next if px < x0 || py < y0 || px > x1 || py > y1

          covered = coverage(zone.vertices, x, y, feather)
          next if covered <= 0

          surface = zone.surface
          src = if surface.nil?
                  [0, 0, 0, 0]
                elsif surface.filter == "linear"
                  Sampler.sample_bilinear(surface, u, v)
                else
                  Sampler.sample_nearest_texel_bottom_left(surface, u, v)
                end
          weight = covered * zone.alpha
          inv = 1 - a
          r += src[0] * weight * inv
          g += src[1] * weight * inv
          b += src[2] * weight * inv
          a += src[3] * weight * inv
          break if a >= 0.999
        end

        inv = 1 - a
        out[0] = rt.f32(r + background[0] * background_alpha * inv)
        out[1] = rt.f32(g + background[1] * background_alpha * inv)
        out[2] = rt.f32(b + background[2] * background_alpha * inv)
        out[3] = rt.f32(a + background_alpha * inv)
      end
    end
  end
end
