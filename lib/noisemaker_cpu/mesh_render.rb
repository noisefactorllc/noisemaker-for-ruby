# frozen_string_literal: true

# CPU triangle-mesh rasterizer for `drawMode: 'triangles'` passes
# (`render/meshRender`).
#
# Faithful port of noisemaker-cpu src/effects/cpu/mesh-render.js. The canonical
# pass executor cannot run these through the per-pixel fragment-kernel
# machinery (they rasterize a variable number of triangles rather than filling
# every destination pixel exactly once), so -- like the scatter adapters in
# points-deposit.js -- this is a hand-ported function dispatched by the
# renderer, keyed by "effect_id:program". The port follows the upstream draw
# exactly (shaders/src/runtime/backends/webgl2.js triangle-mesh mode):
#   - drawArrays(TRIANGLES) over one texel per vertex of the mesh positions
#     texture, consecutive texel triples forming a de-indexed triangle soup
#     (`parseOBJ` packs exactly that order, so no index buffer exists on
#     either side);
#   - depth test LESS against a per-pass depth buffer cleared to 1.0,
#     back-face culling with CCW = front, blending disabled;
#   - the vertex stage is `render.vert` (mesh texture fetch, scale/offset,
#     Rz*Ry*Rx rotation in degrees, orthographic projection with viewScale and
#     aspect divide, z mapped to [0, 1] over nearZ -10 / farZ 10) and the
#     fragment stage is `render.frag` (Blinn-Phong diffuse/specular, ambient,
#     Fresnel rim, optional wireframe discard via screen-space normal
#     derivatives, gamma 1/2.2).
# Floating point follows GLSL f32 semantics via _f32 on every elementary op.
# Rasterization samples pixel centers with an inclusive inside test; exact
# edge behavior is implementation-defined on real GPUs, which is why
# meshRender parity is graded rather than byte-exact.

require_relative "surface"
require_relative "texture_format"

module NoisemakerCpu
  module MeshRender
    @mesh_adapters = {} # "effect_id:program" -> callable(dest, uniforms, external_inputs)

    def self.register(effect_id, program, adapter)
      @mesh_adapters["#{effect_id}:#{program}"] = adapter
    end

    def self.get_adapter(effect_id, program)
      @mesh_adapters["#{effect_id}:#{program}"]
    end

    def self._f32(x)
      [x].pack("e").unpack1("e")
    end

    def self._vec3(x, y, z)
      [_f32(x), _f32(y), _f32(z)]
    end

    # JS Math.hypot(a, b, c): sqrt of the sum of squares without intermediate
    # overflow. Equivalent to nested Math.hypot pair calls at these ranges.
    def self._hypot3(a, b, c)
      Math.sqrt(a * a + b * b + c * c)
    end

    # Vertex stage of render.vert for one mesh texel. pos_data/normal_data are
    # 4-element arrays from the packed mesh texture.
    def self.vertex_stage(pos_data, normal_data, uniforms)
      position = _vec3(pos_data[0], pos_data[1], pos_data[2])
      normal = _vec3(normal_data[0], normal_data[1], normal_data[2])
      mesh_scale = uniforms["meshScale"]
      position = _vec3(_f32(position[0] * mesh_scale), _f32(position[1] * mesh_scale), _f32(position[2] * mesh_scale))
      position = _vec3(
        _f32(position[0] + uniforms["meshOffsetX"]),
        _f32(position[1] + uniforms["meshOffsetY"]),
        _f32(position[2] + uniforms["meshOffsetZ"])
      )
      deg2rad = _f32(3.14159265 / 180.0)
      rx = _f32(uniforms["rotateX"] * deg2rad)
      ry = _f32(uniforms["rotateY"] * deg2rad)
      rz = _f32(uniforms["rotateZ"] * deg2rad)
      cx = _f32(Math.cos(rx)); sx = _f32(Math.sin(rx))
      cy = _f32(Math.cos(ry)); sy = _f32(Math.sin(ry))
      cz = _f32(Math.cos(rz)); sz = _f32(Math.sin(rz))
      # mat3 rotationZ * rotationY * rotationX (GLSL column-major constructor values inlined).
      rot_x = [1, 0, 0, 0, cx, sx, 0, -sx, cx]
      rot_y = [cy, 0, sy, 0, 1, 0, -sy, 0, cy]
      rot_z = [cz, -sz, 0, sz, cz, 0, 0, 0, 1]
      mul = lambda do |a, b|
        # a * b with column-major mat3 layout: out[col*3+row] = sum a[k*3+row]*b[col*3+k]
        out = Array.new(9)
        3.times do |col|
          3.times do |row|
            out[col * 3 + row] = _f32(_f32(a[row] * b[col * 3]) + _f32(a[3 + row] * b[col * 3 + 1]) + _f32(a[6 + row] * b[col * 3 + 2]))
          end
        end
        out
      end
      rotation = mul.call(mul.call(rot_z, rot_y), rot_x)
      apply = lambda do |m, v|
        _vec3(
          _f32(_f32(m[0] * v[0]) + _f32(m[3] * v[1]) + _f32(m[6] * v[2])),
          _f32(_f32(m[1] * v[0]) + _f32(m[4] * v[1]) + _f32(m[7] * v[2])),
          _f32(_f32(m[2] * v[0]) + _f32(m[5] * v[1]) + _f32(m[8] * v[2]))
        )
      end
      rotated_pos = apply.call(rotation, position)
      rotated_normal = apply.call(rotation, normal)
      rotated_pos[0] = _f32(rotated_pos[0] + uniforms["posX"])
      rotated_pos[1] = _f32(rotated_pos[1] + uniforms["posY"])
      clip_x = _f32(rotated_pos[0] * uniforms["viewScale"])
      clip_y = _f32(rotated_pos[1] * uniforms["viewScale"])
      clip_x = _f32(clip_x / uniforms["aspect"])
      near_z = -10.0
      far_z = 10.0
      ndc_z = _f32(_f32(rotated_pos[2] - near_z) / _f32(far_z - near_z))
      { clip_x: clip_x, clip_y: clip_y, ndc_z: ndc_z, rotated_normal: rotated_normal, rotated_pos: rotated_pos }
    end

    def self._vec3_normalize(v)
      len_sq = _f32(_f32(_f32(v[0] * v[0]) + _f32(v[1] * v[1])) + _f32(v[2] * v[2]))
      return _vec3(0, 0, 0) if len_sq.zero?

      inv_len = _f32(1 / Math.sqrt(len_sq))
      _vec3(_f32(v[0] * inv_len), _f32(v[1] * inv_len), _f32(v[2] * inv_len))
    end

    # Fragment stage of render.frag for one covered pixel. Returns the color
    # triple, or nil for a wireframe discard.
    def self.fragment_stage(v_normal, v_position, uniforms)
      normal = _vec3_normalize(v_normal)
      light_dir = _vec3_normalize(_vec3(uniforms["lightDirection"][0], uniforms["lightDirection"][1], uniforms["lightDirection"][2]))
      view_dir = _vec3(0, 0, 1)
      mesh_color = _vec3(uniforms["meshColor"][0], uniforms["meshColor"][1], uniforms["meshColor"][2])
      ambient = _vec3(
        _f32(uniforms["ambientColor"][0] * mesh_color[0]),
        _f32(uniforms["ambientColor"][1] * mesh_color[1]),
        _f32(uniforms["ambientColor"][2] * mesh_color[2])
      )
      diffuse_factor = [_f32(normal[0] * light_dir[0] + normal[1] * light_dir[1] + normal[2] * light_dir[2]), 0].max
      diffuse = _vec3(
        _f32(_f32(uniforms["diffuseColor"][0] * diffuse_factor) * mesh_color[0] * uniforms["diffuseIntensity"]),
        _f32(_f32(uniforms["diffuseColor"][1] * diffuse_factor) * mesh_color[1] * uniforms["diffuseIntensity"]),
        _f32(_f32(uniforms["diffuseColor"][2] * diffuse_factor) * mesh_color[2] * uniforms["diffuseIntensity"])
      )
      half_dir = _vec3_normalize(_vec3(_f32(light_dir[0] + view_dir[0]), _f32(light_dir[1] + view_dir[1]), _f32(light_dir[2] + view_dir[2])))
      spec_angle = [_f32(half_dir[0] * normal[0] + half_dir[1] * normal[1] + half_dir[2] * normal[2]), 0].max
      specular_factor = spec_angle.zero? && uniforms["shininess"].zero? ? 1 : spec_angle**uniforms["shininess"]
      specular = _vec3(
        _f32(_f32(uniforms["specularColor"][0] * _f32(specular_factor)) * uniforms["specularIntensity"]),
        _f32(_f32(uniforms["specularColor"][1] * _f32(specular_factor)) * uniforms["specularIntensity"]),
        _f32(_f32(uniforms["specularColor"][2] * _f32(specular_factor)) * uniforms["specularIntensity"])
      )
      rim_base = _f32(1 - [ _f32(normal[0] * view_dir[0] + normal[1] * view_dir[1] + normal[2] * view_dir[2]), 0].max)
      rim = rim_base.zero? && uniforms["rimPower"].zero? ? 1 : rim_base**uniforms["rimPower"]
      rim_light = _vec3(_f32(rim * uniforms["rimIntensity"]), _f32(rim * uniforms["rimIntensity"]), _f32(rim * uniforms["rimIntensity"]))
      color = _vec3(
        _f32(_f32(ambient[0] + diffuse[0]) + _f32(specular[0] + rim_light[0])),
        _f32(_f32(ambient[1] + diffuse[1]) + _f32(specular[1] + rim_light[1])),
        _f32(_f32(ambient[2] + diffuse[2]) + _f32(specular[2] + rim_light[2]))
      )
      if uniforms["wireframe"] == 1
        # dFdx/dFdy of the interpolated normal, evaluated analytically per
        # triangle by the caller (screen-space derivatives are
        # per-triangle-constant here up to the GPU's 2x2 helper-quad mixing at
        # edges). Caller passes them via uniforms.
        ndx = uniforms["_dFdxNormal"]
        ndy = uniforms["_dFdyNormal"]
        normal_edge = _f32(_f32(_hypot3(_f32(ndx[0]), _f32(ndx[1]), _f32(ndx[2])) + _hypot3(_f32(ndy[0]), _f32(ndy[1]), _f32(ndy[2]))))
        return nil if normal_edge < 0.1 # discard: interior pixel

        color = _vec3(mesh_color[0], mesh_color[1], mesh_color[2])
      end
      # Gamma correction: pow(color, 1/2.2)
      gamma = _f32(1 / 2.2)
      _vec3(_f32(color[0]**gamma), _f32(color[1]**gamma), _f32(color[2]**gamma))
    end

    register("render/meshRender", "render", lambda do |destination, uniforms, external_inputs|
      mesh_render_triangles_adapter(destination, uniforms, external_inputs)
    end)

    def self.mesh_render_triangles_adapter(destination, resolved_uniforms, external_inputs)
      mesh_data = external_inputs && (external_inputs["meshData"] || external_inputs[:meshData])
      raise "render/meshRender requires external mesh data (externalInputs.meshData)" unless mesh_data

      positions = mesh_data["positions"] || mesh_data["positionData"]
      normals = mesh_data["normalData"]
      tex_width = mesh_data["texWidth"]
      tex_height = mesh_data["texHeight"]
      width = destination.width
      height = destination.height
      data = destination.data
      full_res = resolved_uniforms["fullResolution"]
      aspect = full_res ? _f32(full_res[0].to_f / full_res[1]) : _f32(width.to_f / height)
      resolved_uniforms = resolved_uniforms.merge("aspect" => aspect, "wireframe" => resolved_uniforms.key?("wireframe") ? resolved_uniforms["wireframe"] : 0)
      # Per-pixel depth buffer cleared to 1.0 (gl.clear(DEPTH_BUFFER_BIT) each pass).
      depth = Array.new(width * height, 1.0)
      covered = 0
      vertex_count = tex_width * tex_height
      triangle_count = (vertex_count / 3).to_i
      (0...triangle_count).each do |tri|
        verts = []
        all_invalid = true
        3.times do |v|
          texel = tri * 3 + v
          x = texel % tex_width
          y = (texel / tex_width).to_i
          pi = (y * tex_width + x) * 4
          pos_data = [positions[pi], positions[pi + 1], positions[pi + 2], positions[pi + 3]]
          normal_data = [normals[pi], normals[pi + 1], normals[pi + 2], normals[pi + 3]]
          all_invalid = false if pos_data[3] != 0
          stage = vertex_stage(pos_data, normal_data, resolved_uniforms)
          # Window coordinates, GL bottom-up: px = (ndcX + 1) / 2 * width.
          px = _f32(_f32(_f32(stage[:clip_x] + 1) * 0.5) * width)
          py = _f32(_f32(_f32(stage[:clip_y] + 1) * 0.5) * height)
          verts << { px: px, py: py, z: stage[:ndc_z], normal: stage[:rotated_normal], position: stage[:rotated_pos] }
        end
        next if all_invalid

        v0, v1, v2 = verts
        # Signed area in GL window space (y-up); CCW = front face.
        area = _f32(_f32(_f32(v1[:px] - v0[:px]) * _f32(v2[:py] - v0[:py])) - _f32(_f32(v2[:px] - v0[:px]) * _f32(v1[:py] - v0[:py])))
        next unless area > 0 # back face or degenerate: culled

        # Analytic screen-space derivatives of the interpolated normal (wireframe).
        det = _f32(_f32(_f32(v0[:px] * _f32(v1[:py] - v2[:py])) + _f32(v1[:px] * _f32(v2[:py] - v0[:py]))) + _f32(v2[:px] * _f32(v0[:py] - v1[:py])))
        d_fdx_normal = [0, 0, 0]
        d_fdy_normal = [0, 0, 0]
        if resolved_uniforms["wireframe"] == 1 && det != 0
          # dFdx(vNormal) and dFdy(vNormal): standard barycentric-gradient
          # numerators with the full determinant dividing the SUM (the det
          # division applies to the complete edge-function numerator, not just
          # its last term).
          dndx = lambda do |comp|
            _f32((_f32(_f32(v0[:normal][comp] * _f32(v1[:py] - v2[:py])) + _f32(v1[:normal][comp] * _f32(v2[:py] - v0[:py]))) + _f32(v2[:normal][comp] * _f32(v0[:py] - v1[:py]))) / det)
          end
          dndy = lambda do |comp|
            _f32((_f32(_f32(v0[:normal][comp] * _f32(v2[:px] - v1[:px])) + _f32(v1[:normal][comp] * _f32(v0[:px] - v2[:px]))) + _f32(v2[:normal][comp] * _f32(v1[:px] - v0[:px]))) / det)
          end
          d_fdx_normal = [dndx.call(0), dndx.call(1), dndx.call(2)]
          d_fdy_normal = [dndy.call(0), dndy.call(1), dndy.call(2)]
        end
        frag_uniforms = resolved_uniforms["wireframe"] == 1 ?
          resolved_uniforms.merge("_dFdxNormal" => d_fdx_normal, "_dFdyNormal" => d_fdy_normal) :
          resolved_uniforms
        # Bounding box of the triangle, clamped to the viewport.
        min_x = [_js_floor([v0[:px], v1[:px], v2[:px]].min - 0.5), 0].max
        max_x = [_js_ceil([v0[:px], v1[:px], v2[:px]].max - 0.5), width - 1].min
        min_y_gl = [_js_floor([v0[:py], v1[:py], v2[:py]].min - 0.5), 0].max
        max_y_gl = [_js_ceil([v0[:py], v1[:py], v2[:py]].max - 0.5), height - 1].min
        (min_y_gl..max_y_gl).each do |py_gl|
          # Surface rows are top-down; GL window y is bottom-up.
          row = height - 1 - py_gl
          cy = _f32(py_gl + 0.5)
          (min_x..max_x).each do |px_gl|
            cx = _f32(px_gl + 0.5)
            # Barycentric coordinates via edge functions (CCW, positive area).
            b0 = _f32(_f32(_f32(v1[:px] - v0[:px]) * _f32(cy - v0[:py])) - _f32(_f32(v1[:py] - v0[:py]) * _f32(cx - v0[:px]))) / area
            b1 = _f32(_f32(_f32(v2[:px] - v1[:px]) * _f32(cy - v1[:py])) - _f32(_f32(v2[:py] - v1[:py]) * _f32(cx - v1[:px]))) / area
            b2 = 1 - _f32(b0 + b1)
            next unless b0 >= 0 && b1 >= 0 && b2 >= 0

            z = _f32(_f32(_f32(b0 * v0[:z]) + _f32(b1 * v1[:z])) + _f32(b2 * v2[:z]))
            depth_index = row * width + px_gl
            next unless z < depth[depth_index] # depthFunc LESS

            depth[depth_index] = z
            v_normal = [
              _f32(_f32(_f32(b0 * v0[:normal][0]) + _f32(b1 * v1[:normal][0])) + _f32(b2 * v2[:normal][0])),
              _f32(_f32(_f32(b0 * v0[:normal][1]) + _f32(b1 * v1[:normal][1])) + _f32(b2 * v2[:normal][1])),
              _f32(_f32(_f32(b0 * v0[:normal][2]) + _f32(b1 * v1[:normal][2])) + _f32(b2 * v2[:normal][2])),
            ]
            v_position = [
              _f32(_f32(_f32(b0 * v0[:position][0]) + _f32(b1 * v1[:position][0])) + _f32(b2 * v2[:position][0])),
              _f32(_f32(_f32(b0 * v0[:position][1]) + _f32(b1 * v1[:position][1])) + _f32(b2 * v2[:position][1])),
              _f32(_f32(_f32(b0 * v0[:position][2]) + _f32(b1 * v1[:position][2])) + _f32(b2 * v2[:position][2])),
            ]
            color = fragment_stage(v_normal, v_position, frag_uniforms)
            next unless color # wireframe discard

            out_index = depth_index * 4
            data[out_index] = color[0]
            data[out_index + 1] = color[1]
            data[out_index + 2] = color[2]
            data[out_index + 3] = 1
            covered += 1
          end
        end
      end
      { pixels: covered }
    end

    # JS Math.floor / Math.ceil (both return -0 for negative-zero-ish inputs;
    # the numeric value is what matters here).
    def self._js_floor(v)
      f = v.to_f.floor
      f
    end

    def self._js_ceil(v)
      v.to_f.ceil
    end
  end
end