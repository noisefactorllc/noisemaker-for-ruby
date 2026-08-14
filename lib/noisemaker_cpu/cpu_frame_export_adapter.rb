# frozen_string_literal: true

require_relative "surface"

module NoisemakerCpu
  FrameExportFrame = Struct.new(:width, :height, :row_stride, :data, keyword_init: true)

  class CpuFrameExportAdapter
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    CpuSlot = Struct.new(
      :index, :width, :height, :alpha_mode, :data, :frame, :ready, :destroyed,
      keyword_init: true
    )

    def create_slot(index, descriptor)
      byte_length = validate_descriptor(descriptor)
      data = ("\0" * byte_length).b
      frame = FrameExportFrame.new(
        width: descriptor["width"], height: descriptor["height"],
        row_stride: descriptor["width"] * 4, data: data
      )
      CpuSlot.new(
        index: index, width: descriptor["width"], height: descriptor["height"],
        alpha_mode: descriptor["alphaMode"], data: data, frame: frame,
        ready: false, destroyed: false
      )
    end

    def begin(slot, surface, _timestamp = nil)
      assert_usable(slot)
      raise "CPU frame export slot is already pending" if slot.ready
      unless surface.is_a?(NoisemakerCpu::Surface)
        raise TypeError, "CPU frame export requires a Surface frame"
      end
      unless surface.width == slot.width && surface.height == slot.height
        raise "CPU frame export source extent #{surface.width}x#{surface.height} " \
              "does not match configured extent #{slot.width}x#{slot.height}"
      end

      source = surface.data
      index = 0
      while index < source.length
        alpha = source[index + 3]
        color_scale = slot.alpha_mode == "premultiplied" ? alpha : 1
        slot.data.setbyte(index, byte_from_float(source[index] * color_scale))
        slot.data.setbyte(index + 1, byte_from_float(source[index + 1] * color_scale))
        slot.data.setbyte(index + 2, byte_from_float(source[index + 2] * color_scale))
        slot.data.setbyte(index + 3, byte_from_float(slot.alpha_mode == "opaque" ? 1 : alpha))
        index += 4
      end
      slot.ready = true
    end

    def poll(slot)
      assert_usable(slot)
      slot.ready
    end

    def read(slot)
      assert_usable(slot)
      raise "CPU frame export slot is not ready" unless slot.ready

      slot.ready = false
      slot.frame
    end

    def destroy_slot(slot)
      return if slot.nil? || slot.destroyed

      slot.destroyed = true
      slot.ready = false
    end

    private

    def validate_descriptor(descriptor)
      raise TypeError, "Frame export descriptor must be a Hash" unless descriptor.is_a?(Hash)

      %w[width height].each do |name|
        value = descriptor[name]
        unless value.is_a?(Integer) && value.positive? && value <= MAX_SAFE_INTEGER
          raise ArgumentError, "Frame export #{name} must be a positive integer"
        end
      end
      unless descriptor["format"] == "rgba8unorm"
        raise TypeError, "CPU frame export format must be 'rgba8unorm'"
      end
      unless %w[srgb display-p3].include?(descriptor["colorSpace"])
        raise TypeError, "CPU frame export colorSpace must be 'srgb' or 'display-p3'"
      end
      unless %w[opaque straight premultiplied].include?(descriptor["alphaMode"])
        raise TypeError, "CPU frame export alphaMode must be 'opaque', 'straight', or 'premultiplied'"
      end
      fps = descriptor["fps"]
      unless fps.is_a?(Numeric) && fps.real? && fps.to_f.finite? && fps.positive?
        raise ArgumentError, "Frame export fps must be finite and positive"
      end
      if descriptor["height"] > NoisemakerCpu::Surface::MAX_SURFACE_PIXELS / descriptor["width"]
        raise ArgumentError, "Surface exceeds the 16,777,216 pixel limit"
      end

      descriptor["width"] * descriptor["height"] * 4
    end

    def byte_from_float(value)
      return 0 unless value.finite? && value.positive?
      return 255 if value >= 1

      ((value * 255) + 0.5).truncate
    end

    def assert_usable(slot)
      raise "CPU frame export slot is not usable" if slot.nil? || slot.destroyed
    end
  end
end
