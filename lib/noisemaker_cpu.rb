# frozen_string_literal: true

# Pure-Ruby CPU implementation of the Noisemaker shader engine — the Ruby port
# of noisemaker-cpu, at byte-parity with the reference JavaScript engine.
#
# The GLSL compiler is build-time only. Rendering loads the vendored kernels
# and the shared enum data, without compiling or fetching shader source.

require_relative "noisemaker_cpu/version"
require_relative "noisemaker_cpu/uint_math"
require_relative "noisemaker_cpu/texture_format"
require_relative "noisemaker_cpu/surface"
require_relative "noisemaker_cpu/sampler"
require_relative "noisemaker_cpu/palette_data"
require_relative "noisemaker_cpu/runtime"
require_relative "noisemaker_cpu/draw_ops"
require_relative "noisemaker_cpu/png"
require_relative "noisemaker_cpu/kernel_cache"
require_relative "noisemaker_cpu/overlay_gen"
require_relative "noisemaker_cpu/adapters"
require_relative "noisemaker_cpu/pass_runner"
require_relative "noisemaker_cpu/sink_manager"
require_relative "noisemaker_cpu/frame_export_queue"
require_relative "noisemaker_cpu/cpu_frame_export_adapter"
require_relative "noisemaker_cpu/renderer"
require_relative "noisemaker_cpu/dsl"
