# frozen_string_literal: true

# PNG codec -- faithful port of noisemaker-cpu src/node/png.js (via the
# Python port's png.py). Core-module-only (Ruby stdlib zlib).
#
# Encodes Surface objects as 8-bit RGBA PNGs (color type 6, no interlace,
# filter type 0/None per scanline) and decodes arbitrary well-formed 8-bit
# non-interlaced PNGs (grayscale, RGB, palette, gray+alpha, RGBA; all five
# row filters) back into Surface objects. Mirrors png.js's structural
# validation (chunk ordering, CRC32 checks) and its decompression-bomb /
# pixel-count guards.

require "zlib"

require_relative "surface"

module NoisemakerCpu
  module PNG
    SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*").b.freeze
    MAX_PNG_PIXELS = 16_777_216
    MAX_PNG_ENCODED_BYTES = 256 * 1024 * 1024
    MAX_PNG_DECODED_BYTES = 96 * 1024 * 1024

    COMPONENTS_BY_COLOR_TYPE = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.freeze

    def self._chunk(chunk_type, data = nil)
      data = "" if data.nil?
      body = (chunk_type.b + data.b)
      crc = Zlib.crc32(body) & 0xFFFFFFFF
      [data.bytesize].pack("N") + body + [crc].pack("N")
    end

    # Encode a Surface (RGBA float32, top-down) as 8-bit RGBA PNG bytes.
    def self.encode_png(surface)
      width, height = surface.width, surface.height
      raise "PNG exceeds the 16,777,216 pixel limit\n" if height > (MAX_PNG_PIXELS / width)

      ihdr = [width, height, 8, 6, 0, 0, 0].pack("NNCCCCC")

      rgba = surface.to_rgba8.b
      stride = width * 4
      scanlines = String.new("", encoding: Encoding::ASCII_8BIT)
      (0...height).each do |y|
        scanlines << "\x00".b
        scanlines << rgba[y * stride, stride]
      end

      idat = Zlib::Deflate.deflate(scanlines, 9)

      SIGNATURE + _chunk("IHDR", ihdr) + _chunk("IDAT", idat) + _chunk("IEND")
    end

    def self._paeth(left, up, upper_left)
      estimate = left + up - upper_left
      ld = (estimate - left).abs
      ud = (estimate - up).abs
      uld = (estimate - upper_left).abs
      return left if ld <= ud && ld <= uld
      return up if ud <= uld

      upper_left
    end

    # Match Node's Buffer#toString('ascii'): mask off the high bit of each byte.
    def self._ascii(data)
      data.b.each_byte.map { |b| (b & 0x7F).chr }.join
    end

    # Inflate a zlib stream, raising if the output would exceed max_length.
    # Mirrors Node's inflateSync(compressed, { maxOutputLength }).
    def self._bounded_inflate(compressed, max_length)
      inflater = Zlib::Inflate.new
      out = String.new("", encoding: Encoding::ASCII_8BIT)
      begin
        inflater.inflate(compressed) do |chunk|
          out << chunk
          raise "decompressed data exceeds the expected length\n" if out.bytesize > max_length
        end
      rescue Zlib::Error => e
        raise "invalid zlib stream: #{e.message}\n"
      end
      raise "invalid or truncated zlib stream\n" unless inflater.finished?

      out
    end

    def self._decode_scanlines(compressed, width, height, bpp)
      stride = width * bpp
      expected = (stride + 1) * height
      raise "PNG decoded scanlines exceed the 96 MiB limit\n" if expected > MAX_PNG_DECODED_BYTES

      filtered = begin
        _bounded_inflate(compressed, expected)
      rescue StandardError => e
        raise "PNG decompressed data exceeds the expected scanline length or is invalid: #{e.message}"
      end
      raise "PNG scanline data has an invalid length\n" if filtered.bytesize != expected

      filt = filtered.unpack("C*")
      decoded = Array.new(stride * height, 0)
      (0...height).each do |y|
        source_row = y * (stride + 1)
        target_row = y * stride
        filter = filt[source_row]
        raise "Unsupported PNG row filter #{filter}\n" if filter > 4

        (0...stride).each do |x|
          raw = filt[source_row + x + 1]
          left = x >= bpp ? decoded[target_row + x - bpp] : 0
          up = y > 0 ? decoded[target_row + x - stride] : 0
          ul = (y > 0 && x >= bpp) ? decoded[target_row + x - stride - bpp] : 0
          predictor =
            case filter
            when 0 then 0
            when 1 then left
            when 2 then up
            when 3 then (left + up) >> 1
            else _paeth(left, up, ul)
            end
          decoded[target_row + x] = (raw + predictor) & 0xFF
        end
      end
      decoded
    end

    # Decode a non-interlaced, 8-bit PNG into a Surface (RGBA float32, top-down).
    def self.decode_png(png)
      png = png.b
      raise "PNG exceeds the 256 MiB encoded input limit\n" if png.bytesize > MAX_PNG_ENCODED_BYTES
      if png.bytesize < SIGNATURE.bytesize || png[0, SIGNATURE.bytesize] != SIGNATURE
        raise "Input is not a PNG image\n"
      end

      offset = SIGNATURE.bytesize
      width = 0
      height = 0
      bit_depth = 0
      color_type = -1
      interlace = 0
      palette = nil
      transparency = nil
      seen_header = false
      seen_palette = false
      seen_transparency = false
      seen_idat = false
      idat_closed = false
      seen_end = false
      idat_chunks = []

      while offset + 12 <= png.bytesize
        length = png[offset, 4].unpack1("N")
        chunk_end = offset + 12 + length
        raise "PNG contains a truncated chunk\n" if chunk_end > png.bytesize

        chunk_type = _ascii(png[offset + 4, 4])
        chunk_data = png[offset + 8, length]
        expected_crc = png[offset + 8 + length, 4].unpack1("N")
        actual_crc = Zlib.crc32(png[offset + 4, 4 + length]) & 0xFFFFFFFF
        raise "PNG CRC mismatch in #{chunk_type}\n" if actual_crc != expected_crc

        case chunk_type
        when "IHDR"
          if seen_header || offset != SIGNATURE.bytesize
            raise "PNG IHDR must appear exactly once and first\n"
          end
          raise "PNG IHDR has an invalid length\n" if length != 13

          seen_header = true
          width = chunk_data[0, 4].unpack1("N")
          height = chunk_data[4, 4].unpack1("N")
          raise "PNG dimensions must be positive\n" if width == 0 || height == 0
          raise "PNG exceeds the 16,777,216 pixel limit\n" if height > (MAX_PNG_PIXELS / width)

          bit_depth = chunk_data.getbyte(8)
          color_type = chunk_data.getbyte(9)
          compression = chunk_data.getbyte(10)
          filter_method = chunk_data.getbyte(11)
          raise "Unsupported PNG compression or filter method\n" if compression != 0 || filter_method != 0

          interlace = chunk_data.getbyte(12)
        when "PLTE"
          if !seen_header || seen_palette || seen_idat
            raise "PNG PLTE must appear at most once before IDAT\n"
          end

          seen_palette = true
          palette = chunk_data
        when "tRNS"
          if !seen_header || seen_transparency || seen_idat
            raise "PNG tRNS must appear at most once before IDAT\n"
          end

          seen_transparency = true
          transparency = chunk_data
        when "IDAT"
          raise "PNG IDAT chunks must be consecutive and follow IHDR\n" if !seen_header || idat_closed

          seen_idat = true
          idat_chunks << chunk_data
        when "IEND"
          raise "PNG IEND must be empty and follow IDAT\n" if !seen_idat || length != 0

          seen_end = true
          offset = chunk_end
          break
        else
          idat_closed = true if seen_idat
          raise "Unsupported critical PNG chunk #{chunk_type}\n" if chunk_type[0, 1] == chunk_type[0, 1].upcase
        end
        offset = chunk_end
      end

      raise "PNG is missing required IHDR, IDAT, or IEND chunks\n" unless seen_header && seen_idat && seen_end
      raise "PNG contains trailing data after IEND\n" if offset != png.bytesize
      raise "Unsupported PNG bit depth #{bit_depth}; expected 8\n" if bit_depth != 8
      raise "Interlaced PNG images are not supported\n" if interlace != 0

      components = COMPONENTS_BY_COLOR_TYPE[color_type]
      raise "Unsupported PNG color type #{color_type}\n" unless components
      if color_type == 3 && (palette.nil? || palette.empty? || (palette.bytesize % 3 != 0))
        raise "Indexed PNG is missing a valid palette\n"
      end
      unless transparency.nil?
        raise "Grayscale PNG tRNS must contain one 16-bit sample\n" if color_type == 0 && transparency.bytesize != 2
        raise "True-color PNG tRNS must contain three 16-bit samples\n" if color_type == 2 && transparency.bytesize != 6
        if color_type == 3 && transparency.bytesize > palette.bytesize / 3
          raise "Indexed PNG tRNS exceeds its palette length\n"
        end
        raise "PNG color type #{color_type} cannot contain tRNS\n" if color_type == 4 || color_type == 6
      end

      transparent_gray = (color_type == 0 && !transparency.nil?) ? transparency.unpack1("n") : -1
      transparent_red = -1
      transparent_green = -1
      transparent_blue = -1
      if color_type == 2 && !transparency.nil?
        transparent_red, transparent_green, transparent_blue = transparency.unpack("nnn")
      end

      decoded = _decode_scanlines(idat_chunks.join, width, height, components)
      trns = transparency.nil? ? [] : transparency.unpack("C*")
      pal = palette.nil? ? [] : palette.unpack("C*")
      out = Array.new(width * height * 4)
      (0...(width * height)).each do |pixel|
        source = pixel * components
        target = pixel * 4
        case color_type
        when 0
          value = decoded[source]
          out[target] = value
          out[target + 1] = value
          out[target + 2] = value
          out[target + 3] = (value == transparent_gray) ? 0 : 255
        when 2
          r = decoded[source]
          g = decoded[source + 1]
          b = decoded[source + 2]
          out[target] = r
          out[target + 1] = g
          out[target + 2] = b
          out[target + 3] = (r == transparent_red && g == transparent_green && b == transparent_blue) ? 0 : 255
        when 3
          index = decoded[source]
          raise "PNG palette index #{index} is out of range\n" if index * 3 + 2 >= pal.length

          out[target] = pal[index * 3]
          out[target + 1] = pal[index * 3 + 1]
          out[target + 2] = pal[index * 3 + 2]
          out[target + 3] = (!transparency.nil? && index < trns.length) ? trns[index] : 255
        when 4
          value = decoded[source]
          out[target] = value
          out[target + 1] = value
          out[target + 2] = value
          out[target + 3] = decoded[source + 1]
        else
          out[target] = decoded[source]
          out[target + 1] = decoded[source + 1]
          out[target + 2] = decoded[source + 2]
          out[target + 3] = decoded[source + 3]
        end
      end
      NoisemakerCpu::Surface.from_rgba8(width, height, out.pack("C*"))
    end
  end
end
