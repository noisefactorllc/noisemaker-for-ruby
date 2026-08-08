# frozen_string_literal: true

# Kernel loader + size-bounded LRU cache for runtime-compiled kernel source.
#
# The Ruby analogue of the reference engine's `new Function(...)` + Map cache:
# kernel source (a file whose last expression is `{ kernel: coderef,
# uses_derivatives: 0|1 }`) is compiled with eval and memoized, keyed by an
# opaque caller-supplied string, bounded by total source byte size.

module NoisemakerCpu
  class KernelCache
    # A fresh, empty binding per kernel load. Never TOPLEVEL_BINDING(.dup):
    # Binding#dup shares the main script's local-variable environment, so a
    # kernel local named `size`/`seed` would assign straight into the host
    # program's variables (observed live: a kernel clobbered the parity
    # harness's `size` with a texture-size array).
    def self.empty_binding
      binding
    end

    def self.load_kernel(source, name = nil)
      name = "<kernel>" if name.nil?
      begin
        result = eval(source, empty_binding, name) # rubocop:disable Security/Eval -- this is the codegen contract
      rescue ScriptError, StandardError => e
        raise "kernel '#{name}' failed to compile: #{e.message}"
      end
      unless result.is_a?(Hash) && result[:kernel].respond_to?(:call)
        raise "kernel '#{name}' did not yield a { kernel: ... } hash\n"
      end
      result
    end

    def initialize(max_bytes: 64 * 1024 * 1024)
      @max_bytes = max_bytes
      @entries = {} # key -> { kernel:, size: }
      @order = [] # LRU order, oldest first
      @bytes = 0
      @hits = 0
      @misses = 0
    end

    def _touch(key)
      @order = @order.reject { |k| k == key } + [key]
    end
    private :_touch

    def get(key, source_factory)
      entry = @entries[key]
      if entry
        @hits += 1
        _touch(key)
        return entry[:kernel]
      end
      @misses += 1
      source = source_factory.call
      kernel = self.class.load_kernel(source, key)
      @entries[key] = { kernel: kernel, size: source.bytesize }
      @bytes += source.bytesize
      @order.push(key)
      _evict
      kernel
    end

    def _evict
      while @bytes > @max_bytes && @order.length > 1
        key = @order.shift
        evicted = @entries.delete(key)
        @bytes -= evicted[:size]
      end
    end
    private :_evict

    def stats
      {
        entries: @entries.length,
        bytes: @bytes,
        hits: @hits,
        misses: @misses
      }
    end

    def clear
      @entries = {}
      @order = []
      @bytes = 0
    end
  end
end
