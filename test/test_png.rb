# frozen_string_literal: true

# Mirror of noisemaker-for-python/tests/test_png.py, translated to Ruby /
# minitest. png.rb's only cross-worker dependency is Worker A's surface.rb
# (Surface#width/#height/#to_rgba8, Surface.from_rgba8 -- a "thin" surface,
# per the port contract's dependency note for Worker D); this file checks
# for it at run time and skips every PNG-dependent assertion (with a clear
# reason) if it is not yet present, rather than failing to load altogether.

require "minitest/autorun"
require "zlib"
require "tmpdir"

SURFACE_PATH = File.expand_path("../lib/noisemaker_cpu/surface.rb", __dir__)
PNG_LOADABLE = File.exist?(SURFACE_PATH)

require_relative "../lib/noisemaker_cpu/png" if PNG_LOADABLE

# The JS PNG-encoder cross-check needs a sibling noisemaker-cpu checkout + node.
# Python's test_png.py falls back to a sibling "noisemaker-cpu" dir; in this
# repo layout the JS oracle actually lives at "noisemaker-for-cpu" (per the
# port contract's reference table), so that's the Ruby default here.
CPU_DIR = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path("../../noisemaker-for-cpu", __dir__)

SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*").b.freeze

# Independent PNG chunk builder (length + type + data + CRC32) used only by
# tests that hand-construct PNG bytes, so decode_png is exercised against
# input it did not itself produce.
def _png_chunk(chunk_type, data = "")
  body = chunk_type.b + data.b
  crc = Zlib.crc32(body) & 0xFFFFFFFF
  [data.bytesize].pack("N") + body + [crc].pack("N")
end

def _ihdr(width, height, color_type = 6)
  [width, height, 8, color_type, 0, 0, 0].pack("NNCCCCC")
end

def _paeth_predictor(left, up, upper_left)
  estimate = left + up - upper_left
  ld = (estimate - left).abs
  ud = (estimate - up).abs
  uld = (estimate - upper_left).abs
  return left if ld <= ud && ld <= uld
  return up if ud <= uld

  upper_left
end

# Hand-filter raw top-down RGBA scanlines with PNG filter type 4 (Paeth).
def _filter4_encode(pixels, width, height, bpp)
  stride = width * bpp
  out = Array.new((stride + 1) * height, 0)
  (0...height).each do |y|
    src_row = y * stride
    dst_row = y * (stride + 1)
    out[dst_row] = 4 # filter type: Paeth
    (0...stride).each do |x|
      raw = pixels[src_row + x]
      left = x >= bpp ? pixels[src_row + x - bpp] : 0
      up = y > 0 ? pixels[src_row - stride + x] : 0
      upper_left = (y > 0 && x >= bpp) ? pixels[src_row - stride + x - bpp] : 0
      predictor = _paeth_predictor(left, up, upper_left)
      out[dst_row + 1 + x] = (raw - predictor) & 0xFF
    end
  end
  out.pack("C*")
end

def _build_png(width, height, filtered_scanlines)
  idat = Zlib::Deflate.deflate(filtered_scanlines, 9)
  SIGNATURE + _png_chunk("IHDR", _ihdr(width, height)) + _png_chunk("IDAT", idat) + _png_chunk("IEND")
end

class TestPng < Minitest::Test
  def setup
    skip "surface.rb (Worker A) not yet available -- png.rb cannot load" unless PNG_LOADABLE
  end

  def test_encode_png_has_signature_and_chunk_markers
    surface = NoisemakerCpu::Surface.from_rgba8(
      2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255].pack("C*")
    )
    output = NoisemakerCpu::PNG.encode_png(surface)
    assert_equal SIGNATURE, output[0, 8]
    assert_includes output, "IHDR".b
    assert_includes output, "IDAT".b
    assert_includes output, "IEND".b
  end

  def test_round_trip_3x2_surface
    raw = [
      10, 20, 30, 255,
      40, 50, 60, 200,
      70, 80, 90, 128,
      100, 110, 120, 64,
      130, 140, 150, 32,
      160, 170, 180, 0,
    ].pack("C*")
    surface = NoisemakerCpu::Surface.from_rgba8(3, 2, raw)
    decoded = NoisemakerCpu::PNG.decode_png(NoisemakerCpu::PNG.encode_png(surface))
    assert_equal 3, decoded.width
    assert_equal 2, decoded.height
    assert_equal surface.to_rgba8, decoded.to_rgba8
  end

  def test_cross_check_against_js_encoder
    skip "needs node + a sibling noisemaker-cpu checkout" unless system("which node > /dev/null 2>&1") && Dir.exist?(CPU_DIR)

    Dir.mktmpdir do |tmp_dir|
      output_path = File.join(tmp_dir, "nmpng_fix.png")
      ok = system(
        "node", "bin/noisemaker-cpu.js", "effect", "synth/solid",
        "--width", "4", "--height", "4",
        "--param", "color=#4080c0",
        "--output", output_path,
        chdir: CPU_DIR, out: File::NULL, err: File::NULL
      )
      assert ok, "node bin/noisemaker-cpu.js invocation failed"

      surface = NoisemakerCpu::PNG.decode_png(File.binread(output_path))
      assert_equal 4, surface.width
      assert_equal 4, surface.height
      rgba = surface.to_rgba8
      expected_pixel = [0x40, 0x80, 0xC0, 0xFF].pack("C*")
      (0...rgba.bytesize).step(4) do |i|
        assert_equal expected_pixel, rgba[i, 4]
      end
    end
  end

  def test_decode_png_paeth_filter_round_trip
    width = 2
    height = 2
    bpp = 4
    raw = [
      10, 20, 30, 40,
      50, 60, 70, 80,
      90, 100, 110, 120,
      200, 210, 220, 230,
    ].pack("C*")
    filtered = _filter4_encode(raw.unpack("C*"), width, height, bpp)
    # Sanity: the hand-filter actually used filter type 4 on every row.
    assert_equal 4, filtered.getbyte(0)
    assert_equal 4, filtered.getbyte(width * bpp + 1)

    png_bytes = _build_png(width, height, filtered)
    surface = NoisemakerCpu::PNG.decode_png(png_bytes)
    assert_equal width, surface.width
    assert_equal height, surface.height
    assert_equal raw, surface.to_rgba8
  end

  def test_decode_png_rejects_oversized_pixel_count
    bogus_ihdr = _ihdr(16_777_217, 1)
    bogus = SIGNATURE + _png_chunk("IHDR", bogus_ihdr) + _png_chunk("IDAT", Zlib::Deflate.deflate("\x00" * 5)) +
            _png_chunk("IEND")
    err = assert_raises(RuntimeError) { NoisemakerCpu::PNG.decode_png(bogus) }
    assert_match(/16,777,216 pixel limit/, err.message)
  end

  def test_decode_png_rejects_decompression_bomb
    bomb_idat = Zlib::Deflate.deflate("\x00" * (1024 * 1024))
    bomb = SIGNATURE + _png_chunk("IHDR", _ihdr(1, 1)) + _png_chunk("IDAT", bomb_idat) + _png_chunk("IEND")
    err = assert_raises(RuntimeError) { NoisemakerCpu::PNG.decode_png(bomb) }
    assert_match(/exceeds the expected scanline length/, err.message)
  end
end
