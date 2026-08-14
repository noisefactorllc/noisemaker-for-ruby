# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/noisemaker_cpu"

class TestOutputRuntime < Minitest::Test
  class RecordingSink
    attr_reader :events

    def initialize(result: true, submit_error: nil, close_error: nil, on_submit: nil)
      @events = []
      @result = result
      @submit_error = submit_error
      @close_error = close_error
      @on_submit = on_submit
    end

    def configure(descriptor)
      @events << [:configure, descriptor.dup]
    end

    def submit(frame, timestamp)
      @events << [:submit, frame, timestamp]
      return @on_submit.call(self, frame, timestamp) if @on_submit
      raise @submit_error if @submit_error

      @result
    end

    def close(options = nil)
      @events << [:close, options]
      raise @close_error if @close_error
    end
  end

  class FakeAdapter
    attr_accessor :create_error, :destroy_error
    attr_reader :slots

    def initialize
      @slots = []
    end

    def create_slot(index, descriptor)
      raise "slot creation failed" if @create_error == index

      slot = { index: index, descriptor: descriptor, ready: false, value: nil, destroys: 0 }
      @slots << slot
      slot
    end

    def begin(slot, value, _timestamp)
      raise "begin failed" if value == :begin_error

      slot[:ready] = false
      slot[:value] = value
    end

    def poll(slot)
      raise "poll failed" if slot[:ready] == :poll_error

      slot[:ready]
    end

    def read(slot)
      raise "read failed" if slot[:ready] == :read_error

      slot[:value]
    end

    def destroy_slot(slot)
      slot[:destroys] += 1
      raise "destroy #{slot[:index]} failed" if @destroy_error == slot[:index]
    end
  end

  def descriptor(width: 1, height: 1, alpha_mode: "straight")
    {
      "width" => width, "height" => height, "format" => "rgba8unorm",
      "colorSpace" => "srgb", "alphaMode" => alpha_mode, "fps" => 60
    }
  end

  def assert_error(pattern, &block)
    error = assert_raises(StandardError, &block)
    assert_match pattern, error.message
    error
  end

  def export_bytes(surface, alpha_mode)
    queue = NoisemakerCpu::FrameExportQueue.new(
      NoisemakerCpu::CpuFrameExportAdapter.new, slots: 2
    )
    received = nil
    queue.configure(descriptor(width: surface.width, height: surface.height, alpha_mode: alpha_mode))
    assert queue.enqueue(surface, 42, ->(frame, _timestamp, _context) { received = frame.data.dup })
    queue.poll
    queue.close
    received
  end

  def test_public_api_exports_output_runtime
    assert_equal NoisemakerCpu::CpuRenderer, NoisemakerCpu.const_get(:CpuRenderer)
    assert_equal NoisemakerCpu::FrameExportQueue, NoisemakerCpu.const_get(:FrameExportQueue)
    assert_equal NoisemakerCpu::SinkManager, NoisemakerCpu.const_get(:SinkManager)
  end

  def test_sink_manager_configures_current_and_later_sinks
    first = RecordingSink.new
    later = RecordingSink.new
    manager = NoisemakerCpu::SinkManager.new
    sink_descriptor = { "width" => 2, "height" => 3 }

    manager.add(first)
    manager.configure(sink_descriptor)
    manager.add(later)

    assert_equal [[:configure, sink_descriptor]], first.events
    assert_equal [[:configure, sink_descriptor]], later.events
    assert_error(/already registered/) { manager.add(later) }
  end

  def test_sink_manager_counts_exact_outcomes_and_isolates_failures
    reported = []
    manager = NoisemakerCpu::SinkManager.new(on_error: lambda do |error, sink|
      reported << [error.message, sink]
      raise "reporter failed"
    end)
    accepted = RecordingSink.new(result: true)
    dropped = RecordingSink.new(result: false)
    ignored = RecordingSink.new(result: 1)
    failed = RecordingSink.new(submit_error: RuntimeError.new("sink failed"))
    later = RecordingSink.new(result: true)
    [accepted, dropped, ignored, failed, later].each { |sink| manager.add(sink) }

    manager.submit(NoisemakerCpu::Surface.new(1, 1), 10)

    assert_equal({ accepted: 1, dropped: 0, failed: 0 }, manager.stats[accepted])
    assert_equal({ accepted: 0, dropped: 1, failed: 0 }, manager.stats[dropped])
    assert_equal({ accepted: 0, dropped: 0, failed: 0 }, manager.stats[ignored])
    assert_equal({ accepted: 0, dropped: 0, failed: 1 }, manager.stats[failed])
    assert_equal({ accepted: 1, dropped: 0, failed: 0 }, manager.stats[later])
    assert_equal [["sink failed", failed]], reported
  end

  def test_sink_manager_supports_reentrant_removal_and_terminal_close
    manager = NoisemakerCpu::SinkManager.new
    self_removing = nil
    self_removing = RecordingSink.new(on_submit: lambda do |_sink, _frame, _timestamp|
      manager.remove(self_removing)
      true
    end)
    later = RecordingSink.new
    manager.add(self_removing)
    manager.add(later)
    manager.submit(NoisemakerCpu::Surface.new(1, 1), 20)

    assert_equal %i[submit close], self_removing.events.map(&:first)
    assert_equal [:submit], later.events.map(&:first)
    refute manager.stats.key?(self_removing)

    first = RecordingSink.new(close_error: RuntimeError.new("first close failed"))
    second = RecordingSink.new
    closing = NoisemakerCpu::SinkManager.new
    closing.add(first)
    closing.add(second)
    retained_stats = closing.stats
    error = assert_raises(RuntimeError) { closing.close({ "backendLost" => true }) }
    assert_match(/first close failed/, error.message)
    assert_same retained_stats, closing.stats
    assert_empty retained_stats
    assert_equal [:close], second.events.map(&:first)
    closing.close
    assert_error(/closed/) { closing.add(RecordingSink.new) }
  end

  def test_frame_export_queue_enforces_bounds_backpressure_context_and_reuse
    assert_error(/adapter/) { NoisemakerCpu::FrameExportQueue.new(Object.new) }
    assert_error(/2 through 8/) { NoisemakerCpu::FrameExportQueue.new(FakeAdapter.new, slots: 1) }
    assert_error(/2 through 8/) { NoisemakerCpu::FrameExportQueue.new(FakeAdapter.new, slots: 2.0) }

    adapter = FakeAdapter.new
    queue = NoisemakerCpu::FrameExportQueue.new(adapter, slots: 2)
    completed = []
    context = { sequence: 7 }
    queue.configure({ "width" => 1, "height" => 1 })
    assert queue.enqueue("one", 10, ->(*args) { completed << args }, context)
    assert queue.enqueue("two", 20, ->(*) {})
    refute queue.enqueue("overflow", 30, ->(*) {})
    adapter.slots[1][:ready] = true
    queue.poll

    assert_empty completed
    adapter.slots[0][:ready] = true
    queue.poll
    assert_equal [["one", 10, context]], completed
    assert queue.enqueue("replacement", 40, ->(*) {})
    assert_equal({ accepted: 3, dropped: 1, completed: 2, failed: 0 }, queue.stats)
  end

  def test_frame_export_queue_isolates_failures_and_requires_boolean_poll_results
    errors = []
    adapter = FakeAdapter.new
    queue = NoisemakerCpu::FrameExportQueue.new(
      adapter, slots: 2, on_error: ->(error) { errors << error.message }
    )
    queue.configure({ "width" => 1, "height" => 1 })
    refute queue.enqueue(:begin_error, 1, ->(*) {})
    assert queue.enqueue("invalid poll", 2, ->(*) { flunk "invalid poll invoked callback" })
    adapter.slots[0][:ready] = 1
    queue.poll
    assert queue.enqueue("callback", 3, ->(*) { raise "callback failed" })
    adapter.slots[0][:ready] = true
    queue.poll

    assert_equal ["begin failed", "Frame export adapter poll must return a boolean", "callback failed"], errors
    assert queue.available?
    assert_equal({ accepted: 2, dropped: 0, completed: 0, failed: 3 }, queue.stats)
  end

  def test_frame_export_queue_rolls_back_and_closes_every_slot
    failing = FakeAdapter.new
    failing.create_error = 1
    queue = NoisemakerCpu::FrameExportQueue.new(failing, slots: 2)
    assert_error(/slot creation failed/) { queue.configure({ "width" => 1, "height" => 1 }) }
    assert_equal [1], failing.slots.map { |slot| slot[:destroys] }
    refute queue.available?

    adapter = FakeAdapter.new
    closing = NoisemakerCpu::FrameExportQueue.new(adapter, slots: 2)
    closing.configure({ "width" => 1, "height" => 1 })
    adapter.destroy_error = 0
    assert_error(/destroy 0 failed/) { closing.close }
    assert_equal [1, 1], adapter.slots.map { |slot| slot[:destroys] }
    closing.close
    refute closing.enqueue("late", 0, ->(*) {})

    lost_adapter = FakeAdapter.new
    lost = NoisemakerCpu::FrameExportQueue.new(lost_adapter, slots: 2)
    lost.configure({ "width" => 1, "height" => 1 })
    lost.close(backend_lost: true)
    assert_equal [0, 0], lost_adapter.slots.map { |slot| slot[:destroys] }

    non_boolean_adapter = FakeAdapter.new
    non_boolean = NoisemakerCpu::FrameExportQueue.new(non_boolean_adapter, slots: 2)
    non_boolean.configure({ "width" => 1, "height" => 1 })
    non_boolean.close(backend_lost: :false)
    assert_equal [1, 1], non_boolean_adapter.slots.map { |slot| slot[:destroys] }
  end

  def test_cpu_frame_export_preserves_rows_storage_identity_and_alpha_modes
    surface = NoisemakerCpu::Surface.new(1, 2, [1, 0, 0.5, 1, 0, 0.25, 1, 1])
    queue = NoisemakerCpu::FrameExportQueue.new(NoisemakerCpu::CpuFrameExportAdapter.new, slots: 2)
    frames = []
    queue.configure(descriptor(width: 1, height: 2))
    assert queue.enqueue(surface, 42, ->(frame, *) { frames << [frame, frame.data.dup] })
    surface.clear([0, 1, 0, 1])
    queue.poll
    first_frame = frames[0][0]
    first_data = first_frame.data
    assert queue.enqueue(surface, 43, ->(frame, *) { frames << [frame, frame.data.dup] })
    queue.poll

    assert_equal [255, 0, 128, 255, 0, 64, 255, 255], frames[0][1].bytes
    assert_equal [0, 255, 0, 255] * 2, frames[1][1].bytes
    assert_same first_frame, frames[1][0]
    assert_same first_data, frames[1][0].data

    alpha = NoisemakerCpu::Surface.new(1, 2, [2, 0.002, 0.5, 0.25, -1, 0.5, 1.5, 0.5])
    assert_equal [255, 1, 128, 64, 0, 128, 255, 128], export_bytes(alpha, "straight").bytes
    assert_equal [255, 1, 128, 255, 0, 128, 255, 255], export_bytes(alpha, "opaque").bytes
    assert_equal [128, 0, 32, 64, 0, 64, 191, 128], export_bytes(alpha, "premultiplied").bytes
  end

  def test_cpu_frame_export_writes_directly_into_preallocated_storage
    surface = NoisemakerCpu::Surface.new(2, 1, [1, 0, 0.5, 1, 0, 0.25, 1, 1])
    adapter = NoisemakerCpu::CpuFrameExportAdapter.new
    slot = adapter.create_slot(0, descriptor(width: 2))
    packed_frame_arrays = []
    original_pack = Array.instance_method(:pack)
    Array.define_method(:pack) do |*args|
      packed_frame_arrays << length if length == surface.data.length
      original_pack.bind_call(self, *args)
    end
    begin
      adapter.begin(slot, surface, 0)
    ensure
      Array.define_method(:pack, original_pack)
    end

    assert_empty packed_frame_arrays
    assert_equal [255, 0, 128, 255, 0, 64, 255, 255], slot.data.bytes
  end

  def test_cpu_frame_export_rejects_invalid_descriptors_and_extent_mismatch
    adapter = NoisemakerCpu::CpuFrameExportAdapter.new
    assert_error(/positive integer/) do
      adapter.create_slot(0, descriptor(width: 9_007_199_254_740_992))
    end
    assert_error(/16,777,216 pixel limit/) do
      adapter.create_slot(0, descriptor(width: 16_777_217))
    end

    errors = []
    queue = NoisemakerCpu::FrameExportQueue.new(
      adapter, slots: 2, on_error: ->(error) { errors << error.message }
    )
    queue.configure(descriptor(width: 2))
    refute queue.enqueue(NoisemakerCpu::Surface.new(1, 1), 0, ->(*) {})
    assert_match(/source extent 1x1 does not match configured extent 2x1/, errors[0])
    assert_equal({ accepted: 0, dropped: 0, completed: 0, failed: 1 }, queue.stats)
    assert queue.available?
  end

  def test_cpu_renderer_configures_sinks_submits_successes_and_validates_first
    renderer = NoisemakerCpu::CpuRenderer.new
    sink = RecordingSink.new
    renderer.add_sink(sink)
    source = "search synth\nsolid(color: [0.2, 0.4, 0.6]).write(o0)\nrender(o0)"

    first = renderer.render(source, width: 2, height: 1, presentation_timestamp: 100)
    second = renderer.render(source, width: 2, height: 1, presentation_timestamp: 200)
    third = renderer.render(source, width: 3, height: 1, presentation_timestamp: 300)
    assert_equal %i[configure submit submit configure submit], sink.events.map(&:first)
    assert_same first, sink.events[1][1]
    assert_same second, sink.events[2][1]
    assert_same third, sink.events[4][1]
    assert_equal({ accepted: 3, dropped: 0, failed: 0 }, renderer.sink_manager.stats[sink])
    assert_instance_of NoisemakerCpu::FrameExportQueue, renderer.create_frame_export_queue(slots: 2)

    invalid = NoisemakerCpu::CpuRenderer.new
    untouched = RecordingSink.new
    invalid.add_sink(untouched)
    [
      [{ width: 0 }, /width must be a positive integer/],
      [{ height: 0 }, /height must be a positive integer/],
      [{ seed: 1.5 }, /seed must be an integer/],
      [{ time: Float::NAN }, /time must be finite/]
    ].each do |options, pattern|
      assert_error(pattern) { invalid.render(source, **options) }
    end
    assert_empty untouched.events
  end

  def test_cpu_renderer_does_not_submit_failures_and_disposal_is_idempotent
    renderer = NoisemakerCpu::CpuRenderer.new
    sink = RecordingSink.new
    renderer.add_sink(sink)
    assert_error(/has not been written/) do
      renderer.render("search filter\nread(o4).invert().write(o0)\nrender(o0)", width: 1, height: 1)
    end
    assert_equal [:configure], sink.events.map(&:first)
    renderer.dispose
    renderer.dispose
    assert_equal %i[configure close], sink.events.map(&:first)
    assert_error(/closed/) { renderer.add_sink(RecordingSink.new) }
  end
end
