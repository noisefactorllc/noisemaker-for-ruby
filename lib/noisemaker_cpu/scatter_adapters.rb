# frozen_string_literal: true

require_relative "sampler"
require_relative "uint_math"

module NoisemakerCpu
  module ScatterAdapters
    GOLDEN_RATIO_CONJUGATE = 0.618033988749895
    TAU_APPROX = 6.283185
    QUAD_CORNERS = [[-1, -1], [1, -1], [-1, 1], [1, 1]].freeze
    @adapters = {}

    def self.register(key, callable)
      raise TypeError, "scatter adapter key must not be empty" unless key.is_a?(String) && !key.empty?
      raise TypeError, "scatter adapter must be callable" unless callable.respond_to?(:call)

      @adapters[key] = callable
    end

    def self.run(key, pass, uniforms, inputs, destination)
      adapter = @adapters[key]
      raise "missing CPU scatter adapter #{key.inspect}" if adapter.nil?

      adapter.call(pass, uniforms, inputs, destination)
    end

    def self.keys
      @adapters.keys
    end

    def self.f32(value)
      [value].pack("e").unpack1("e")
    end

    def self.fract(value)
      value - value.floor
    end

    def self.texel_fetch_agent(surface, sx, sy)
      x = [[sx, 0].max, surface.width - 1].min
      shader_y = [[sy, 0].max, surface.height - 1].min
      row = surface.height - 1 - shader_y
      surface.data[(row * surface.width + x) * 4, 4]
    end

    def self.scatter_point_pixel(clip_x, clip_y, clip_w, width, height)
      return nil unless clip_w > 0

      col = ((clip_x.fdiv(clip_w) * 0.5 + 0.5) * width).floor
      gl_row = ((clip_y.fdiv(clip_w) * 0.5 + 0.5) * height).floor
      return nil unless col.finite? && gl_row.finite?
      return nil if col.negative? || col >= width || gl_row.negative? || gl_row >= height

      ((height - 1 - gl_row) * width + col) * 4
    rescue FloatDomainError
      nil
    end

    def self.compute_clip_center(x, y, z, uniforms)
      return [x * 2 - 1, y * 2 - 1] if uniforms["viewMode"].to_i == 0

      two_dimensional = z.abs < 1.0 && x.between?(0.0, 1.0) && y.between?(0.0, 1.0)
      px = two_dimensional ? x - 0.5 : x
      py = two_dimensional ? y - 0.5 : y
      pz = two_dimensional ? 0.0 : z

      cos_x = Math.cos(uniforms["rotateX"].to_f)
      sin_x = Math.sin(uniforms["rotateX"].to_f)
      x1 = px
      y1 = py * cos_x - pz * sin_x
      z1 = py * sin_x + pz * cos_x
      cos_y = Math.cos(uniforms["rotateY"].to_f)
      sin_y = Math.sin(uniforms["rotateY"].to_f)
      x2 = x1 * cos_y + z1 * sin_y
      cos_z = Math.cos(uniforms["rotateZ"].to_f)
      sin_z = Math.sin(uniforms["rotateZ"].to_f)
      fx = x2 * cos_z - y1 * sin_z + uniforms["posX"].to_f
      fy = x2 * sin_z + y1 * cos_z + uniforms["posY"].to_f
      scale = uniforms["viewScale"].to_f
      return [fx * 3.5 * scale, fy * 3.5 * scale] if two_dimensional

      [(fx / 40.0) * scale, (fy / 40.0) * scale]
    end

    def self.each_agent(surface)
      (surface.width * surface.height).times do |index|
        yield index, index % surface.width, index / surface.width
      end
    end

    def self.dla_deposit(_pass, uniforms, inputs, destination)
      energy = uniforms["deposit"].to_f * 0.1
      pixels = 0
      each_agent(inputs["xyzTex"]) do |_index, x, y|
        next if texel_fetch_agent(inputs["velTex"], x, y)[1] < 0.5

        xyz = texel_fetch_agent(inputs["xyzTex"], x, y)
        offset = scatter_point_pixel(xyz[0] * 2 - 1, xyz[1] * 2 - 1, 1, destination.width, destination.height)
        next if offset.nil?

        rgba = texel_fetch_agent(inputs["rgbaTex"], x, y)
        3.times { |channel| destination.data[offset + channel] += rgba[channel] * energy }
        destination.data[offset + 3] += energy
        pixels += 1
      end
      { pixels: pixels }
    end

    def self.lenia_deposit(_pass, uniforms, inputs, destination)
      amount = uniforms["depositAmount"].to_f
      pixels = 0
      each_agent(inputs["xyzTex"]) do |_index, x, y|
        xyz = texel_fetch_agent(inputs["xyzTex"], x, y)
        next if xyz[3] < 0.5

        offset = scatter_point_pixel(xyz[0] * 2 - 1, xyz[1] * 2 - 1, 1, destination.width, destination.height)
        next if offset.nil?

        destination.data[offset] += amount
        destination.data[offset + 3] += 1
        pixels += 1
      end
      { pixels: pixels }
    end

    def self.physarum_deposit(_pass, uniforms, inputs, destination)
      deposit = uniforms["deposit"].to_f
      pixels = 0
      each_agent(inputs["xyzTex"]) do |_index, x, y|
        xyz = texel_fetch_agent(inputs["xyzTex"], x, y)
        next if xyz[3] < 0.5

        offset = scatter_point_pixel(xyz[0] * 2 - 1, xyz[1] * 2 - 1, 1, destination.width, destination.height)
        next if offset.nil?

        rgba = texel_fetch_agent(inputs["rgbaTex"], x, y)
        4.times { |channel| destination.data[offset + channel] += rgba[channel] * deposit }
        pixels += 1
      end
      { pixels: pixels }
    end

    def self.points_render_deposit(_pass, uniforms, inputs, destination)
      threshold = uniforms["density"].to_f / 100.0
      pixels = 0
      each_agent(inputs["xyzTex"]) do |index, x, y|
        next if fract(index * GOLDEN_RATIO_CONJUGATE) > threshold

        xyz = texel_fetch_agent(inputs["xyzTex"], x, y)
        next if xyz[3] < 0.5

        clip = compute_clip_center(xyz[0], xyz[1], xyz[2], uniforms)
        offset = scatter_point_pixel(clip[0], clip[1], 1, destination.width, destination.height)
        next if offset.nil?

        rgba = texel_fetch_agent(inputs["rgbaTex"], x, y)
        4.times { |channel| destination.data[offset + channel] += rgba[channel] }
        pixels += 1
      end
      { pixels: pixels }
    end

    def self.billboard_hash(value, seed)
      bits = NoisemakerCpu::UintMath.float_bits_to_uint(f32(value + seed))
      state = NoisemakerCpu::UintMath.uadd(NoisemakerCpu::UintMath.umul(bits, 747_796_405), 2_891_336_453)
      word = NoisemakerCpu::UintMath.umul(
        NoisemakerCpu::UintMath.uxor(state >> ((state >> 28) + 4), state), 277_803_737
      )
      NoisemakerCpu::UintMath.uxor(word >> 22, word).fdiv(4_294_967_295)
    end

    def self.clamp(value, low, high)
      [[value, low].max, high].min
    end

    def self.smoothstep(edge0, edge1, value)
      amount = clamp((value - edge0).fdiv(edge1 - edge0), 0, 1)
      amount * amount * (3 - 2 * amount)
    end

    def self.sign(value)
      return 1 if value.positive?
      return -1 if value.negative?

      0
    end

    def self.billboard_signed_distance(mode, px, py)
      return Math.sqrt(px * px + py * py) - 0.45 if mode == 1
      return (Math.sqrt(px * px + py * py) - 0.35).abs - 0.08 if mode == 2
      return [px.abs, py.abs].max - 0.4 if mode == 3
      return px.abs + py.abs - 0.45 if mode == 4

      if mode == 5
        radius = 0.25
        k = 1.732050808
        tx = px.abs - radius
        ty = py - 0.04 + radius / k
        if tx + k * ty > 0
          tx, ty = [(tx - k * ty) / 2.0, (-k * tx - ty) / 2.0]
        end
        tx -= clamp(tx, -2.0 * radius, 0.0)
        return -Math.sqrt(tx * tx + ty * ty) * sign(ty)
      end

      radius = 0.35
      rf = 0.4
      k1x = 0.809016994375
      k1y = -0.587785252292
      k2x = -k1x
      k2y = k1y
      sx = px.abs
      sy = py
      dot1 = k1x * sx + k1y * sy
      multiple = [dot1, 0.0].max
      sx -= 2.0 * multiple * k1x
      sy -= 2.0 * multiple * k1y
      dot2 = k2x * sx + k2y * sy
      multiple = [dot2, 0.0].max
      sx = (sx - 2.0 * multiple * k2x).abs
      sy -= 2.0 * multiple * k2y + radius
      bax = rf * -k1y
      bay = rf * k1x - 1.0
      h = clamp((sx * bax + sy * bay).fdiv(bax * bax + bay * bay), 0.0, radius)
      rem_x = sx - bax * h
      rem_y = sy - bay * h
      Math.sqrt(rem_x * rem_x + rem_y * rem_y) * sign(sy * bax - sx * bay)
    end

    def self.billboard_shape_alpha(mode, u, v)
      px = u - 0.5
      py = v - 0.5
      return Math.exp(-(px * px + py * py) * 8.0) unless mode.between?(1, 6)

      1.0 - smoothstep(-0.02, 0.02, billboard_signed_distance(mode, px, py))
    end

    def self.billboard_fragment(mode, sprite, u, v, color, opacity)
      if mode == 0
        sample = if sprite.filter == "linear"
                   NoisemakerCpu::Sampler.sample_bilinear(sprite, u, v)
                 else
                   NoisemakerCpu::Sampler.sample_nearest_bottom_left(sprite, u, v)
                 end
        return 4.times.map { |channel| sample[channel] * color[channel] * opacity }
      end

      alpha = billboard_shape_alpha(mode, u, v)
      [color[0] * alpha * opacity, color[1] * alpha * opacity,
       color[2] * alpha * opacity, alpha * color[3] * opacity]
    end

    def self.premultiplied?(pass)
      blend = pass["blend"]
      blend.is_a?(Array) && blend.map { |value| value.to_s.upcase } == ["ONE", "ONE_MINUS_SRC_ALPHA"]
    end

    def self.billboard_deposit(pass, uniforms, inputs, destination)
      threshold = uniforms["density"].to_f / 100.0
      mode = uniforms["shapeMode"].to_i
      opacity = uniforms["depositOpacity"].to_f / 100.0
      size_variation = uniforms["sizeVariation"].to_f / 100.0
      rotation_variation = uniforms["rotationVar"].to_f / 100.0
      premultiplied = premultiplied?(pass)
      pixels = 0

      each_agent(inputs["xyzTex"]) do |index, x, y|
        next if fract(index * GOLDEN_RATIO_CONJUGATE) > threshold

        xyz = texel_fetch_agent(inputs["xyzTex"], x, y)
        next if xyz[3] < 0.5

        color = texel_fetch_agent(inputs["rgbaTex"], x, y)
        center_x, center_y = compute_clip_center(xyz[0], xyz[1], xyz[2], uniforms)
        size = uniforms["pointSize"].to_f *
          (1.0 - size_variation * (billboard_hash(index, uniforms["seed"].to_f) - 0.5))
        next unless size > 0

        rotation = rotation_variation * billboard_hash(index + 1234.5, uniforms["seed"].to_f) * TAU_APPROX
        cosine = Math.cos(rotation)
        sine = Math.sin(rotation)
        size_x = size * 0.5 * (2.0 / destination.width)
        size_y = size * 0.5 * (2.0 / destination.height)
        xs = []
        ys = []
        QUAD_CORNERS.each do |ox, oy|
          xs << ((center_x + (ox * cosine - oy * sine) * size_x) * 0.5 + 0.5) * destination.width
          ys << ((center_y + (ox * sine + oy * cosine) * size_y) * 0.5 + 0.5) * destination.height
        end
        col_start = [0, xs.min.floor].max
        col_end = [destination.width - 1, xs.max.ceil].min
        row_start = [0, ys.min.floor].max
        row_end = [destination.height - 1, ys.max.ceil].min

        (row_start..row_end).each do |gl_row|
          dy = (((gl_row + 0.5) / destination.height) * 2 - 1) - center_y
          b = dy / size_y
          storage_row = destination.height - 1 - gl_row
          (col_start..col_end).each do |col|
            dx = (((col + 0.5) / destination.width) * 2 - 1) - center_x
            a = dx / size_x
            offset_x = a * cosine + b * sine
            offset_y = -a * sine + b * cosine
            next if offset_x < -1 || offset_x > 1 || offset_y < -1 || offset_y > 1

            source = billboard_fragment(
              mode, inputs["spriteTex"], offset_x * 0.5 + 0.5, offset_y * 0.5 + 0.5, color, opacity
            )
            offset = (storage_row * destination.width + col) * 4
            if premultiplied
              inverse_alpha = 1 - source[3]
              4.times do |channel|
                destination.data[offset + channel] = source[channel] + destination.data[offset + channel] * inverse_alpha
              end
            else
              4.times { |channel| destination.data[offset + channel] += source[channel] }
            end
            pixels += 1
          end
        end
      end
      { pixels: pixels }
    end

    register("points/dla:depositGrid", method(:dla_deposit))
    register("points/lenia:deposit", method(:lenia_deposit))
    register("points/physarum:deposit", method(:physarum_deposit))
    register("render/pointsRender:deposit", method(:points_render_deposit))
    register("render/pointsBillboardRender:deposit", method(:billboard_deposit))
  end
end
