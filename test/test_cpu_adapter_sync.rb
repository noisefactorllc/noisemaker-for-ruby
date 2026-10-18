# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu/adapters"
require_relative "../lib/noisemaker_cpu/kernel_cache"
require_relative "../lib/noisemaker_cpu/pass_runner"

class TestCpuAdapterSync < Minitest::Test
  # Raw f32 captures from CPU 4aeb3e1e028b2dc412401f7b7f17c014c603bf14,
  # using crtFactory/snowFactory + GlslCpuRuntime and the input below.
  FIXTURES = File.expand_path("fixtures/cpu-adapter-sync", __dir__)
  CASES = [
    { name: "crt-default", effect: "crt", width: 8, height: 8, alpha: 1, seed: 1, time: 0.25, speed: 1 },
    { name: "crt-tiled", effect: "crt", width: 8, height: 6, alpha: 0.7, seed: 5, time: 0.4, speed: 2.5,
      renderScale: 2, fullResolution: [32, 18], tileOffset: [4, 2] },
    { name: "crt-still", effect: "crt", width: 8, height: 6, alpha: 1, seed: -2, time: 0, speed: 0 },
    { name: "crt-zero", effect: "crt", width: 8, height: 6, alpha: 0, seed: 1, time: 0.25, speed: 1 },
    { name: "snow-quarter", effect: "snow", width: 8, height: 8, alpha: 1, density: 100, time: 0.25 },
    { name: "snow-animated", effect: "snow", width: 8, height: 6, alpha: 0.6, density: 75, time: 0.4 },
    { name: "snow-paused", effect: "snow", width: 8, height: 6, alpha: 1, density: 100, time: 0.6, pause: 1 },
    { name: "snow-zero", effect: "snow", width: 8, height: 6, alpha: 0, density: 100, time: 0.25 },
  ].freeze

  def f32(value)
    [value].pack("e").unpack1("e")
  end

  def context(kase, rt)
    width, height = kase.values_at(:width, :height)
    source = NoisemakerCpu::Surface.new(width, height)
    (width * height).times do |i|
      x, y = i % width, i / width
      source.data[i * 4, 4] = [((x * 3 + y * 5) % 31).fdiv(31),
                              ((x * 11 + y * 7) % 37).fdiv(37),
                              ((x * 17 + y * 23) % 41).fdiv(41), (i % 7).fdiv(7)].map { |v| f32(v) }
    end
    uniforms = { "resolution" => [width, height], "fullResolution" => [0, 0], "tileOffset" => [0, 0],
                 "renderScale" => 1, "seed" => 1, "speed" => 1, "pause" => 0 }
    kase.each { |key, value| uniforms[key.to_s] = value }
    %w[alpha seed time speed density renderScale].each do |key|
      uniforms[key] = f32(uniforms[key]) if uniforms.key?(key)
    end
    NoisemakerCpu::Ctx.new(rt: rt, uniforms: uniforms, textures: { "inputTex" => source },
                          resolution: [width.to_f, height.to_f], time: kase[:time], seed: kase.fetch(:seed, 1))
  end

  def kernel(effect, rt)
    path = File.expand_path("../lib/noisemaker_cpu/bundle/kernels/ruby/filter__#{effect}__#{effect}.rb", __dir__)
    compiled = NoisemakerCpu::KernelCache.load_kernel(File.binread(path), path)
    NoisemakerCpu::Adapters.get_adapter("filter/#{effect}", effect).call(rt, compiled)
  end

  CASES.each do |kase|
    define_method("test_#{kase[:name].tr('-', '_')}_matches_cpu_raw_capture") do
      rt = NoisemakerCpu::Runtime.new
      actual = NoisemakerCpu::PassRunner.run_pass(kernel(kase[:effect], rt), context(kase, rt),
                                                kase[:width], kase[:height])
      expected = File.binread(File.join(FIXTURES, "#{kase[:name]}.f32"))
      assert_equal expected.unpack("L<*"), actual.data.pack("e*").unpack("L<*")
    end
  end

  def test_shared_crt_kernel_uses_each_context_uniforms
    rt = NoisemakerCpu::Runtime.new
    callable = kernel("crt", rt)
    %w[crt-default crt-tiled crt-default].each do |name|
      kase = CASES.find { |entry| entry[:name] == name }
      actual = NoisemakerCpu::PassRunner.run_pass(callable, context(kase, rt), kase[:width], kase[:height])
      expected = File.binread(File.join(FIXTURES, "#{name}.f32"))
      assert_equal expected.unpack("L<*"), actual.data.pack("e*").unpack("L<*")
    end
  end

  def test_crt_fma_rounds_exact_result_at_float32_midpoints
    [
      [[1.1836352348327637, 1.7818914651870728, -1.931027560075904e-9], 1074199463],
      [[1.715787649154663, 1.694210410118103, -3.285236749306364e-9], 1077545661],
      [[1.5398544073104858, 1.8304558992385864, -9.061266736942741e-10], 1077175431],
      [[1, 1.0000001192092896, 5.960464477539063e-8], 1065353218],
      [[3, 0.3333333432674408, -1], 855638016],
    ].each do |args, expected_bits|
      actual = NoisemakerCpu::Adapters::Crt.fma32(*args)
      assert_equal expected_bits, [actual].pack("e").unpack1("L<")
    end
  end

  [1, 4].each do |height|
    define_method("test_crt_width_one_height_#{height}_preserves_cpu_nan_rgb_and_source_alpha") do
      kase = { width: 1, height: height, alpha: 1, time: 0.25 }
      rt = NoisemakerCpu::Runtime.new
      ctx = context(kase, rt)
      actual = NoisemakerCpu::PassRunner.run_pass(kernel("crt", rt), ctx, 1, height)
      assert actual.data.each_slice(4).all? { |pixel| pixel[0, 3].all?(&:nan?) }
      assert_equal ctx.texture_binding("inputTex").data.each_slice(4).map(&:last),
                   actual.data.each_slice(4).map(&:last)
    end
  end

  def test_crt_fragment_coordinates_use_js_int32_coercion
    kase = CASES.first
    rt = NoisemakerCpu::Runtime.new
    callable = kernel("crt", rt)
    expected = File.binread(File.join(FIXTURES, "crt-default.f32")).unpack("e*")[7 * 8 * 4, 4]
    [(2**32) + 0.5, -(2**32) - 0.5, Float::NAN, Float::INFINITY, -Float::INFINITY].each do |coordinate|
      ctx = context(kase, rt)
      ctx.frag_coord = [coordinate, 0.5]
      ctx.uv = [0.5 / 8, 0.5 / 8]
      actual = Array.new(4, 0.0)
      callable.call(ctx, actual)
      assert_equal expected.pack("e*"), actual.pack("e*")
    end
  end

  def test_snow_nonfinite_time_retains_cpu_nan_rgb_and_source_alpha
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |time|
      kase = { width: 1, height: 1, alpha: 1, density: 100, time: time }
      rt = NoisemakerCpu::Runtime.new
      ctx = context(kase, rt)
      ctx.texture_binding("inputTex").data[0, 4] = [0.2, 0.4, 0.6, 0.75].map { |v| f32(v) }
      actual = NoisemakerCpu::PassRunner.run_pass(kernel("snow", rt), ctx, 1, 1)
      assert actual.data[0, 3].all?(&:nan?)
      assert_equal 0.75, actual.data[3]
    end
  end

  def test_snow_zero_alpha_fetch_uses_js_int32_coercion
    kase = CASES.find { |entry| entry[:name] == "snow-zero" }
    rt = NoisemakerCpu::Runtime.new
    callable = kernel("snow", rt)
    expected = File.binread(File.join(FIXTURES, "snow-zero.f32")).unpack("e*")[5 * 8 * 4, 4]
    [(2**32) + 0.5, -(2**32) - 0.5, Float::NAN, Float::INFINITY, -Float::INFINITY].each do |coordinate|
      ctx = context(kase, rt)
      ctx.frag_coord = [coordinate, 0.5]
      actual = Array.new(4, 0.0)
      callable.call(ctx, actual)
      assert_equal expected.pack("e*"), actual.pack("e*")
    end
  end

end
