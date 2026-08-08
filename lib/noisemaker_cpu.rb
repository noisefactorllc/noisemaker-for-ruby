# frozen_string_literal: true

# Pure-Ruby CPU implementation of the Noisemaker shader engine — the Ruby port
# of noisemaker-cpu, at byte-parity with the reference JavaScript engine.
#
# The transpiler (lib/noisemaker_cpu/transpiler/) is build-time only and is not
# loaded here; scripts/build-bundle.rb requires it directly.

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
require_relative "noisemaker_cpu/renderer"
require_relative "noisemaker_cpu/dsl"
