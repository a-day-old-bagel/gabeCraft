#include <shared/shared.inl>

#include <utils/trace.glsl>

#define USE_BLUE_NOISE 1

#define SETTINGS deref(settings)
#define INPUT deref(gpu_input)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
void main() {
    u32vec2 pixel_i = gl_GlobalInvocationID.xy;
    if (pixel_i.x >= INPUT.frame_dim.x ||
        pixel_i.y >= INPUT.frame_dim.y)
        return;

    f32vec2 pixel_p = pixel_i;
    f32vec2 frame_dim = INPUT.frame_dim;
    f32vec2 inv_frame_dim = f32vec2(1.0, 1.0) / frame_dim;
    f32 aspect = frame_dim.x * inv_frame_dim.y;

// #if USE_BLUE_NOISE
//     f32vec2 blue_noise = texelFetch(daxa_texture3D(blue_noise_vec2), ivec3(pixel_i, INPUT.frame_index) & ivec3(127, 127, 63), 0).xy - 0.5;
//     pixel_p += blue_noise * 1.0;
// #else
//     rand_seed(pixel_i.x + pixel_i.y * INPUT.frame_dim.x + u32(INPUT.time * 719393));
//     f32vec2 uv_offset = f32vec2(rand(), rand()) - 0.5;
//     pixel_p += uv_offset * 1.0;
// #endif

    f32vec2 uv = pixel_p * inv_frame_dim;

    uv = (uv - 0.5) * f32vec2(aspect, 1.0) * 2.0;
    f32vec3 ray_pos = create_view_pos(deref(globals).player);
    f32vec3 ray_dir = create_view_dir(deref(globals).player, uv);
    u32vec3 chunk_n = u32vec3(1u << SETTINGS.log2_chunks_per_axis);

    trace(voxel_malloc_global_allocator, voxel_chunks, chunk_n, ray_pos, ray_dir);

    imageStore(daxa_image2D(render_pos_image_id), i32vec2(pixel_i), f32vec4(ray_pos, 0));
}
#undef INPUT
#undef SETTINGS
