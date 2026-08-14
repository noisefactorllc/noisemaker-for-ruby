# frozen_string_literal: true

module NoisemakerCpu
  class SinkManager
    Registration = Struct.new(:sink, :stats, :active, keyword_init: true)
    EMPTY_DESCRIPTOR = {}.freeze

    attr_reader :stats

    def initialize(on_error: nil)
      @on_error = on_error
      @registrations = []
      @registrations_by_sink = {}.compare_by_identity
      @stats = {}.compare_by_identity
      @descriptor = EMPTY_DESCRIPTOR
      @configured = false
      @closed = false
      @iteration_depth = 0
      @has_tombstones = false
    end

    def add(sink)
      raise "SinkManager is closed" if @closed

      validate_sink(sink)
      raise "Sink is already registered" if @registrations_by_sink.key?(sink)

      sink.configure(@descriptor) if @configured
      stats = { accepted: 0, dropped: 0, failed: 0 }
      registration = Registration.new(sink: sink, stats: stats, active: true)
      @registrations << registration
      @registrations_by_sink[sink] = registration
      @stats[sink] = stats
      removed = false
      lambda do
        next if removed

        removed = true
        remove_registration(registration)
      end
    end

    def remove(sink)
      remove_registration(@registrations_by_sink[sink])
    end

    def configure(descriptor = nil)
      return if @closed

      @descriptor = descriptor || EMPTY_DESCRIPTOR
      @configured = true
      @iteration_depth += 1
      begin
        @registrations.each do |registration|
          next unless registration.active

          sink = registration.sink
          begin
            sink.configure(@descriptor)
          rescue StandardError => error
            registration.stats[:failed] += 1
            report(error, sink)
          end
        end
      ensure
        @iteration_depth -= 1
        compact_registrations if @iteration_depth.zero?
      end
    end

    def submit(frame, timestamp)
      return if @closed

      @iteration_depth += 1
      begin
        @registrations.each do |registration|
          next unless registration.active

          sink = registration.sink
          begin
            result = sink.submit(frame, timestamp)
          rescue StandardError => error
            registration.stats[:failed] += 1
            report(error, sink)
            next
          end
          registration.stats[:accepted] += 1 if result.equal?(true)
          registration.stats[:dropped] += 1 if result.equal?(false)
        end
      ensure
        @iteration_depth -= 1
        compact_registrations if @iteration_depth.zero?
      end
    end

    def close(options = nil)
      return if @closed

      @closed = true
      first_error = nil
      @registrations.each do |registration|
        next unless registration.active

        sink = registration.sink
        registration.active = false
        registration.sink = nil
        begin
          options.nil? ? sink.close : sink.close(options)
        rescue StandardError => error
          first_error ||= error
        end
      end
      @registrations.clear
      @registrations_by_sink.clear
      @stats.clear
      @has_tombstones = false
      raise first_error if first_error
    end

    private

    def validate_sink(sink)
      methods = %i[configure submit close]
      return if sink && methods.all? { |name| sink.respond_to?(name) }

      raise TypeError, "Sink must implement configure, submit, and close"
    end

    def remove_registration(registration)
      return unless registration&.active

      sink = registration.sink
      registration.active = false
      registration.sink = nil
      @has_tombstones = true
      if @registrations_by_sink[sink].equal?(registration)
        @registrations_by_sink.delete(sink)
        @stats.delete(sink)
      end
      begin
        sink.close
      ensure
        compact_registrations if @iteration_depth.zero?
      end
    end

    def compact_registrations
      return unless @has_tombstones

      @registrations.select!(&:active)
      @has_tombstones = false
    end

    def report(error, sink)
      return unless @on_error.respond_to?(:call)

      @on_error.call(error, sink)
    rescue StandardError
      nil
    end
  end
end
