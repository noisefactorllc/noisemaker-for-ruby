# frozen_string_literal: true

module NoisemakerCpu
  class FrameExportQueue
    QueueSlot = Struct.new(
      :adapter_slot, :created, :pending, :frame, :timestamp, :on_frame, :context,
      keyword_init: true
    )

    attr_reader :stats

    def initialize(adapter, slots: 3, on_error: nil)
      validate_adapter(adapter)
      unless slots.is_a?(Integer) && slots.between?(2, 8)
        raise ArgumentError, "Frame export slots must be an integer from 2 through 8"
      end

      @adapter = adapter
      @on_error = on_error
      @slots = Array.new(slots) do
        QueueSlot.new(created: false, pending: false)
      end
      @configured = false
      @closed = false
      @stats = { accepted: 0, dropped: 0, completed: 0, failed: 0 }
    end

    def available?
      @configured && !@closed && @slots.any? { |slot| !slot.pending }
    end

    def configure(descriptor)
      return if @closed

      destroy_error = destroy_slots
      @configured = false
      raise destroy_error if destroy_error

      begin
        @slots.each_with_index do |record, index|
          record.adapter_slot = @adapter.create_slot(index, descriptor)
          record.created = true
        end
      rescue StandardError
        cleanup_error = destroy_slots
        report(cleanup_error) if cleanup_error
        raise
      end
      @configured = true
    end

    def enqueue(frame, timestamp, on_frame, context = nil)
      raise TypeError, "Frame export callback must be callable" unless on_frame.respond_to?(:call)

      unless @configured && !@closed
        @stats[:dropped] += 1
        return false
      end
      record = @slots.find { |slot| !slot.pending }
      unless record
        @stats[:dropped] += 1
        return false
      end

      record.pending = true
      record.frame = frame
      record.timestamp = timestamp
      record.on_frame = on_frame
      record.context = context
      begin
        @adapter.begin(record.adapter_slot, frame, timestamp)
      rescue StandardError => error
        release(record)
        @stats[:failed] += 1
        report(error)
        return false
      end
      @stats[:accepted] += 1
      true
    end

    def poll
      return unless @configured && !@closed

      @slots.each do |record|
        next unless record.pending

        begin
          ready = @adapter.poll(record.adapter_slot)
          next if ready.equal?(false)
          raise TypeError, "Frame export adapter poll must return a boolean" unless ready.equal?(true)

          frame = @adapter.read(record.adapter_slot)
          timestamp = record.timestamp
          on_frame = record.on_frame
          context = record.context
        rescue StandardError => error
          release(record)
          @stats[:failed] += 1
          report(error)
          next
        end

        release(record)
        begin
          on_frame.call(frame, timestamp, context)
          @stats[:completed] += 1
        rescue StandardError => error
          @stats[:failed] += 1
          report(error)
        end
      end
    end

    def close(backend_lost: false)
      return if @closed

      @closed = true
      @configured = false
      destroy_error = backend_lost.equal?(true) ? (abandon_slots; nil) : destroy_slots
      @adapter = nil
      raise destroy_error if destroy_error
    end

    private

    def validate_adapter(adapter)
      methods = %i[create_slot begin poll read destroy_slot]
      return if adapter && methods.all? { |name| adapter.respond_to?(name) }

      raise TypeError, "Frame export adapter must implement create_slot, begin, poll, read, and destroy_slot"
    end

    def release(record)
      record.pending = false
      record.frame = nil
      record.timestamp = nil
      record.on_frame = nil
      record.context = nil
    end

    def destroy_slots
      first_error = nil
      @slots.each do |record|
        next unless record.created

        adapter_slot = record.adapter_slot
        record.created = false
        record.adapter_slot = nil
        release(record)
        begin
          @adapter.destroy_slot(adapter_slot)
        rescue StandardError => error
          first_error ||= error
        end
      end
      first_error
    end

    def abandon_slots
      @slots.each do |record|
        record.created = false
        record.adapter_slot = nil
        release(record)
      end
    end

    def report(error)
      return unless @on_error.respond_to?(:call)

      @on_error.call(error)
    rescue StandardError
      nil
    end
  end
end
