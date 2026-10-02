# frozen_string_literal: true

# CPU external-input state for the reactive (MIDI/audio) and mesh (OBJ) effects.
#
# Faithful port of noisemaker-cpu src/runtime/external-input.js (which itself
# ports the rendering-relevant subset of the upstream MidiState/AudioState and
# obj-parser) plus src/runtime/external-textures.js. Deterministic by design:
# no Web MIDI ports, no timing -- fixtures feed raw message bytes through
# MidiState#handle_message exactly like the authority capture harness does.
#
# Float32Array semantics: every array produced here is f32-rounded on store
# (JS writes these values into Float32Arrays), so each assignment goes through
# Surface._f32 / the module's _f32 helper.

module NoisemakerCpu
  module ExternalInput
    UNROUTED = 0

    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    # JS Math.round (ties toward +infinity) -- Ruby Float#round ties away
    # from zero, which differs at negative halves.
    def self._js_round(v)
      f = v.floor
      r = v - f
      r >= 0.5 ? f + 1 : f
    end

    class MidiChannelState
      attr_accessor :key, :velocity, :gate, :keys, :cc, :pitch_bend, :pressure,
        :poly_pressure, :program

      def initialize
        @key = 0
        @velocity = 0
        @gate = 0
        @keys = Array.new(128, 0)
        @cc = Array.new(128, 0)
        @pitch_bend = 8192
        @pressure = 0
        @poly_pressure = Array.new(128, 0)
        @program = 0
      end

      def note_on(key, velocity)
        @key = key
        @velocity = velocity
        @gate = 1
        @keys[key] = velocity
      end

      def note_off(key)
        @gate = 0
        if key.nil?
          @keys.fill(0)
          return
        end
        @keys[key] = 0
        @poly_pressure[key] = 0
      end

      def control_change(controller, value)
        return unless controller.is_a?(Integer) && controller >= 0 && controller <= 127 &&
          value.is_a?(Integer) && value >= 0 && value <= 127

        @cc[controller] = value
        if controller == 120 || controller == 123
          @gate = 0
          @keys.fill(0)
        elsif controller == 121
          128.times { |cc| @cc[cc] = cc == 11 ? 127 : 0 }
          @pitch_bend = 8192
          @pressure = 0
          @poly_pressure.fill(0)
        end
      end

      def reset
        @key = 0
        @velocity = 0
        @gate = 0
        @keys.fill(0)
        @cc.fill(0)
        @pitch_bend = 8192
        @pressure = 0
        @poly_pressure.fill(0)
        @program = 0
      end
    end

    class MidiState
      attr_accessor :channels, :clock_count, :note_grid

      def initialize
        @channels = {}
        (1..16).each { |i| @channels[i] = MidiChannelState.new }
        # MIDI clock pulse count (24 PPQ)
        @clock_count = 0
        # Note grid texture data: 128 keys x 16 channels x RGBA. Row order
        # matches the upstream upload: row 0 is channel 1, R = velocity (0-1),
        # G = gate, B = A = 0.
        @note_grid = Array.new(128 * 16 * 4, 0.0)
      end

      def get_channel(channel)
        return nil unless channel.is_a?(Integer) && channel >= 1 && channel <= 16

        @channels[channel]
      end

      def update_note_grid
        (0...16).each do |ch|
          keys = @channels[ch + 1].keys
          row_offset = ch * 128 * 4
          (0...128).each do |k|
            v = keys[k]
            offset = row_offset + k * 4
            @note_grid[offset] = v.positive? ? ExternalInput._f32(v / 127.0) : 0.0 # R: velocity
            @note_grid[offset + 1] = v.positive? ? 1.0 : 0.0 # G: gate
            # B and A stay 0
          end
        end
      end

      def reset
        (1..16).each { |i| @channels[i].reset }
        @clock_count = 0
        @note_grid.fill(0.0)
      end

      # Process a raw MIDI message: [status, data1, data2]. Mirrors the
      # upstream routing for the message types that reach rendered state;
      # unknown status bytes are ignored. Returns 0 when routed, -1 when the
      # status byte is unhandled.
      def handle_message(data)
        return UNROUTED if data.nil? || data.length < 1

        status = data[0]
        if status == 0xf8
          @clock_count += 1
          return 0
        end
        if status == 0xff
          reset
          return 0
        end
        key = data[1]
        velocity = data[2]
        channel = (status & 0x0f) + 1
        message_type = status & 0xf0
        return -1 if message_type == 0xf0
        return -1 unless key.is_a?(Integer) && key >= 0 && key <= 127
        if message_type != 0xd0 && (!(velocity.is_a?(Integer)) || velocity.negative? || velocity > 127)
          return -1
        end

        channel_state = get_channel(channel)
        return -1 if channel_state.nil?

        if message_type == 0x90 && velocity.positive?
          channel_state.note_on(key, velocity)
          return 0
        end
        if message_type == 0x80 || (message_type == 0x90 && velocity.zero?)
          channel_state.note_off(key)
          return 0
        end
        if message_type == 0xa0
          channel_state.poly_pressure[key] = velocity
          return 0
        end
        if message_type == 0xb0
          channel_state.control_change(key, velocity)
          return 0
        end
        if message_type == 0xc0
          channel_state.program = key
          return 0
        end
        if message_type == 0xd0
          channel_state.pressure = key
          return 0
        end
        if message_type == 0xe0
          channel_state.pitch_bend = key | (velocity << 7)
          return 0
        end
        -1
      end
    end

    # Audio analysis state for the reactive synth effects. Upstream feeds the
    # pipeline 128-float waveform and spectrum arrays normalized to 0-1;
    # fixtures construct this state directly with deterministic arrays.
    class AudioState
      attr_accessor :waveform, :spectrum

      def initialize
        @waveform = Array.new(128, 0.0)
        @spectrum = Array.new(128, 0.0)
      end

      def set_waveform(values)
        raise RangeError, "audio waveform requires exactly 128 samples" unless values.length == 128

        @waveform = values.map { |v| ExternalInput._f32(v) }
      end

      def set_spectrum(values)
        raise RangeError, "audio spectrum requires exactly 128 bins" unless values.length == 128

        @spectrum = values.map { |v| ExternalInput._f32(v) }
      end
    end

    # JS parseInt: parse the longest leading integer prefix, NaN on failure.
    # Callers treat the NaN case as an invalid index (-1 sentinel).
    def self._js_parse_int(text)
      m = /\s*[+-]?\d+/.match(text.to_s)
      m ? m[0].to_i : -1
    end

    # JS parseFloat: parse the longest leading decimal prefix, NaN on failure
    # (which `|| 0` then turns into 0 at the call sites).
    def self._js_parse_float(text)
      m = /[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/.match(text.to_s)
      m ? m[0].to_f : 0.0
    end

    # Parse Wavefront OBJ text into de-indexed triangle-soup vertex data.
    # Fan triangulation for faces with more than three vertices, reversed
    # winding (OBJ CW to GL CCW), per-face normal fallback when a vertex
    # carries no `vn` reference. Returns f32-rounded arrays like the JS
    # Float32Array conversion.
    def self.parse_obj(obj_text)
      raw_positions = []
      raw_normals = []
      raw_uvs = []
      positions = []
      normals = []
      uvs = []

      obj_text.split("\n").each do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.start_with?("#")

        parts = line.split(/\s+/)
        cmd = parts[0]
        case cmd
        when "v"
          raw_positions << [_js_parse_float(parts[1]), _js_parse_float(parts[2]), _js_parse_float(parts[3])]
        when "vn"
          raw_normals << [_js_parse_float(parts[1]), _js_parse_float(parts[2]), _js_parse_float(parts[3])]
        when "vt"
          raw_uvs << [_js_parse_float(parts[1]), _js_parse_float(parts[2])]
        when "f"
          face_verts = []
          (1...parts.length).each do |i|
            indices = parts[i].split("/")
            v_idx = _js_parse_int(indices[0]) - 1
            vt_idx = indices[1] && !indices[1].empty? ? _js_parse_int(indices[1]) - 1 : -1
            vn_idx = indices[2] && !indices[2].empty? ? _js_parse_int(indices[2]) - 1 : -1
            face_verts << { v: v_idx, vt: vt_idx, vn: vn_idx }
          end
          # Fan triangulation, reversed winding: OBJ CW to OpenGL CCW.
          (1...(face_verts.length - 1)).each do |i|
            add_vertex(face_verts[0], raw_positions, raw_normals, raw_uvs, positions, normals, uvs)
            add_vertex(face_verts[i + 1], raw_positions, raw_normals, raw_uvs, positions, normals, uvs)
            add_vertex(face_verts[i], raw_positions, raw_normals, raw_uvs, positions, normals, uvs)
          end
        end
      end

      # If no normals were provided, compute smooth vertex normals: per-triangle
      # face normals averaged by position key, rounded to 1e-4 to merge
      # duplicate vertices.
      if raw_normals.empty? && !positions.empty?
        compute_face_normals(positions, normals)
      end

      {
        "positions" => positions.map { |v| _f32(v) },
        "normals" => normals.map { |v| _f32(v) },
        "uvs" => uvs.map { |v| _f32(v) },
        "vertexCount" => positions.length / 3,
      }
    end

    def self.add_vertex(v, raw_positions, raw_normals, raw_uvs, positions, normals, uvs)
      if v[:v] >= 0 && v[:v] < raw_positions.length
        positions.concat(raw_positions[v[:v]])
      else
        positions.concat([0.0, 0.0, 0.0])
      end
      if v[:vn] >= 0 && v[:vn] < raw_normals.length
        normals.concat(raw_normals[v[:vn]])
      else
        normals.concat([0.0, 0.0, 1.0])
      end
      if v[:vt] >= 0 && v[:vt] < raw_uvs.length
        uvs.concat(raw_uvs[v[:vt]])
      else
        uvs.concat([0.0, 0.0])
      end
    end

    # Pack triangle-soup mesh data into texture-sized RGBA arrays: one texel
    # per vertex, position w = 1 marks a valid vertex (remaining texels keep
    # w = 0). texWidth/texHeight come from the upstream mesh-texture
    # convention (256x256).
    def self.pack_mesh_data_for_textures(positions, normals, uvs, tex_width, tex_height)
      max_vertices = tex_width * tex_height
      vertex_count = positions.length / 3
      used_vertices = [vertex_count, max_vertices].min
      pixel_count = tex_width * tex_height
      position_data = Array.new(pixel_count * 4, 0.0)
      normal_data = Array.new(pixel_count * 4, 0.0)
      uv_data = Array.new(pixel_count * 4, 0.0)
      (0...used_vertices).each do |i|
        pi = i * 4
        vi3 = i * 3
        vi2 = i * 2
        position_data[pi] = _f32(positions[vi3])
        position_data[pi + 1] = _f32(positions[vi3 + 1])
        position_data[pi + 2] = _f32(positions[vi3 + 2])
        position_data[pi + 3] = 1.0
        normal_data[pi] = _f32(normals[vi3])
        normal_data[pi + 1] = _f32(normals[vi3 + 1])
        normal_data[pi + 2] = _f32(normals[vi3 + 2])
        normal_data[pi + 3] = 0.0
        uv_data[pi] = _f32(uvs[vi2])
        uv_data[pi + 1] = _f32(uvs[vi2 + 1])
        uv_data[pi + 2] = 0.0
        uv_data[pi + 3] = 0.0
      end
      {
        "positionData" => position_data,
        "normalData" => normal_data,
        "uvData" => uv_data,
        "vertexCount" => used_vertices,
      }
    end

    # Smooth vertex normals for un-normalized OBJ files: face normals from
    # reversed-winding triangles, averaged per rounded position key,
    # threshold 1e-4. JS arithmetic is f64 with Float32Array stores.
    def self.compute_face_normals(positions, normals)
      vertex_count = positions.length / 3
      triangle_count = vertex_count / 3
      face_normals = Array.new(triangle_count * 3, 0.0)
      (0...triangle_count).each do |tri|
        i0 = tri * 9
        i1 = i0 + 3
        i2 = i0 + 6
        ax = positions[i0]; ay = positions[i0 + 1]; az = positions[i0 + 2]
        bx = positions[i1]; by = positions[i1 + 1]; bz = positions[i1 + 2]
        cx = positions[i2]; cy = positions[i2 + 1]; cz = positions[i2 + 2]
        e1x = bx - ax; e1y = by - ay; e1z = bz - az
        e2x = cx - ax; e2y = cy - ay; e2z = cz - az
        nx = e1y * e2z - e1z * e2y
        ny = e1z * e2x - e1x * e2z
        nz = e1x * e2y - e1y * e2x
        len = Math.sqrt(nx * nx + ny * ny + nz * nz)
        if len > 0.0001
          nx /= len
          ny /= len
          nz /= len
        else
          nx = 0
          ny = 0
          nz = 1
        end
        face_normals[tri * 3] = nx
        face_normals[tri * 3 + 1] = ny
        face_normals[tri * 3 + 2] = nz
      end
      pos_to_normal = {}
      round = ->(v) { _js_round(v * 10_000) / 10_000.0 }
      (0...vertex_count).each do |v|
        px = positions[v * 3]
        py = positions[v * 3 + 1]
        pz = positions[v * 3 + 2]
        key = "#{round.call(px)},#{round.call(py)},#{round.call(pz)}"
        tri_idx = (v / 3).to_i
        acc = (pos_to_normal[key] ||= { nx: 0.0, ny: 0.0, nz: 0.0, count: 0 })
        acc[:nx] += face_normals[tri_idx * 3]
        acc[:ny] += face_normals[tri_idx * 3 + 1]
        acc[:nz] += face_normals[tri_idx * 3 + 2]
        acc[:count] += 1
      end
      pos_to_normal.each_value do |acc|
        len = Math.sqrt(acc[:nx] * acc[:nx] + acc[:ny] * acc[:ny] + acc[:nz] * acc[:nz])
        if len > 0.0001
          acc[:nx] /= len
          acc[:ny] /= len
          acc[:nz] /= len
        else
          acc[:nx] = 0
          acc[:ny] = 0
          acc[:nz] = 1
        end
      end
      (0...vertex_count).each do |v|
        px = positions[v * 3]
        py = positions[v * 3 + 1]
        pz = positions[v * 3 + 2]
        key = "#{round.call(px)},#{round.call(py)},#{round.call(pz)}"
        acc = pos_to_normal[key]
        normals[v * 3] = acc[:nx]
        normals[v * 3 + 1] = acc[:ny]
        normals[v * 3 + 2] = acc[:nz]
      end
    end

    # Data textures uploaded from arrays place array row 0 at GL texture
    # coordinate y = 0 (bottom-left origin). CPU surfaces store rows top-down
    # and the samplers flip the y coordinate, so a data-texture surface must
    # store the uploaded array's rows reversed. The mesh triangles adapter
    # reads the raw uploaded arrays directly (no flip) via external inputs.
    def self.flip_rgba_rows(data, width, height)
      flipped = Array.new(width * height * 4, 0.0)
      (0...height).each do |row|
        source = (height - 1 - row) * width * 4
        (width * 4).times do |i|
          flipped[row * width * 4 + i] = data[source + i]
        end
      end
      flipped
    end

    def self.external_data_surface(data, width, height, format = "rgba32f")
      rows = flip_rgba_rows(data, width, height)
      surface = NoisemakerCpu::Surface.new(width, height, rows)
      surface.format = format
      surface.filter("nearest")
      surface
    end
  end
end