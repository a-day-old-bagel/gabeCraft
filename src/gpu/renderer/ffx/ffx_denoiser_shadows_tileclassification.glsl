/**********************************************************************
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

#pragma once

#include "ffx_denoiser_shadows_util.glsl"

shared int g_FFX_DNSR_Shadows_false_count;
bool FFX_DNSR_Shadows_ThreadGroupAllTrue(bool val) {
    const uint lane_count_in_thread_group = 64;
    if (gl_SubgroupSize == lane_count_in_thread_group) {
        return subgroupAll(val);
    } else {
        barrier();
        g_FFX_DNSR_Shadows_false_count = 0;
        barrier();
        if (!val)
            g_FFX_DNSR_Shadows_false_count = 1;
        barrier();
        return g_FFX_DNSR_Shadows_false_count == 0;
    }
}

void FFX_DNSR_Shadows_SearchSpatialRegion(uvec2 gid, out bool all_in_light, out bool all_in_shadow) {
    // The spatial passes can reach a total region of 1+2+4 = 7x7 around each block.
    // The masks are 8x4, so we need a larger vertical stride

    // Visualization - each x represents a 4x4 block, xx is one entire 8x4 mask as read from the raytracer result
    // Same for yy, these are the ones we are working on right now

    // xx xx xx
    // xx xx xx
    // xx yy xx <-- yy here is the base_tile below
    // xx yy xx
    // xx xx xx
    // xx xx xx

    // All of this should result in scalar ops
    uvec2 base_tile = FFX_DNSR_Shadows_GetTileIndexFromPixelPosition(gid * ivec2(8, 8));

    // Load the entire region of masks in a scalar fashion
    uint combined_or_mask = 0;
    uint combined_and_mask = 0xFFFFFFFF;
    for (int j = -2; j <= 3; ++j) {
        for (int i = -1; i <= 1; ++i) {
            ivec2 tile_index = ivec2(base_tile) + ivec2(i, j);
            tile_index = clamp(tile_index, ivec2(0), ivec2(FFX_DNSR_Shadows_RoundedDivide(FFX_DNSR_Shadows_GetBufferDimensions().x, 8), FFX_DNSR_Shadows_RoundedDivide(FFX_DNSR_Shadows_GetBufferDimensions().y, 4)) - 1);
            const uint linear_tile_index = FFX_DNSR_Shadows_LinearTileIndex(tile_index, FFX_DNSR_Shadows_GetBufferDimensions().x);
            const uint shadow_mask = FFX_DNSR_Shadows_ReadRaytracedShadowMask(linear_tile_index);

            combined_or_mask = combined_or_mask | shadow_mask;
            combined_and_mask = combined_and_mask & shadow_mask;
        }
    }

    all_in_light = combined_and_mask == 0xFFFFFFFFu;
    all_in_shadow = combined_or_mask == 0u;
}

float FFX_DNSR_Shadows_GetLinearDepth(uvec2 did, float depth) {
    const vec2 uv = (did + 0.5f) * FFX_DNSR_Shadows_GetInvBufferDimensions();
    const vec2 ndc = 2.0f * vec2(uv.x, 1.0f - uv.y) - 1.0f;

    vec4 projected = FFX_DNSR_Shadows_GetProjectionInverse() * vec4(ndc, depth, 1);
    return abs(projected.z / projected.w);
}

bool FFX_DNSR_Shadows_IsDisoccluded(uvec2 did, float depth, vec2 velocity) {
    const ivec2 dims = ivec2(FFX_DNSR_Shadows_GetBufferDimensions());
    const vec2 texel_size = FFX_DNSR_Shadows_GetInvBufferDimensions();
    const vec2 uv = (did + 0.5f) * texel_size;
    const vec2 ndc = (2.0f * uv - 1.0f) * vec2(1.0f, -1.0f);
    const vec2 previous_uv = uv - velocity;

    bool is_disoccluded = true;
    if (all(greaterThan(previous_uv, vec2(0.0))) && all(lessThan(previous_uv, vec2(1.0)))) {
        // Read the center values
        vec3 normal = FFX_DNSR_Shadows_ReadNormals(did);

        vec4 clip_space = FFX_DNSR_Shadows_GetReprojectionMatrix() * vec4(ndc, depth, 1.0f);
        clip_space /= clip_space.w; // perspective divide

        // How aligned with the view vector? (the more Z aligned, the higher the depth errors)
        const vec4 homogeneous = FFX_DNSR_Shadows_GetViewProjectionInverse() * vec4(ndc, depth, 1.0f);
        const vec3 world_position = homogeneous.xyz / homogeneous.w; // perspective divide
        const vec3 view_direction = normalize(FFX_DNSR_Shadows_GetEye().xyz - world_position);
        float z_alignment = 1.0f - dot(view_direction, normal);
        z_alignment = pow(z_alignment, 8);

        // Calculate the depth difference
        float linear_depth = FFX_DNSR_Shadows_GetLinearDepth(did, clip_space.z); // get linear depth

        ivec2 idx = ivec2(previous_uv * vec2(dims));
        const float previous_depth = FFX_DNSR_Shadows_GetLinearDepth(idx, FFX_DNSR_Shadows_ReadPreviousDepth(idx));
        const float depth_difference = abs(previous_depth - linear_depth) / linear_depth;

        // Resolve into the disocclusion mask
        const float depth_tolerance = mix(1e-2f, 1e-1f, z_alignment);
        is_disoccluded = depth_difference >= depth_tolerance;
    }

    return is_disoccluded;
}

vec2 FFX_DNSR_Shadows_GetClosestVelocity(ivec2 did, float depth) {
    vec2 closest_velocity = FFX_DNSR_Shadows_ReadVelocity(did);
    float closest_depth = depth;

    float new_depth = subgroupQuadSwapHorizontal(closest_depth);
    vec2 new_velocity = subgroupQuadSwapHorizontal(closest_velocity);
#ifdef INVERTED_DEPTH_RANGE
    if (new_depth > closest_depth)
#else
    if (new_depth < closest_depth)
#endif
    {
        closest_depth = new_depth;
        closest_velocity = new_velocity;
    }

    new_depth = subgroupQuadSwapVertical(closest_depth);
    new_velocity = subgroupQuadSwapVertical(closest_velocity);
#ifdef INVERTED_DEPTH_RANGE
    if (new_depth > closest_depth)
#else
    if (new_depth < closest_depth)
#endif
    {
        closest_depth = new_depth;
        closest_velocity = new_velocity;
    }

    return closest_velocity * vec2(0.5f, -0.5f); // from ndc to uv
}

#define KERNEL_RADIUS 8
float FFX_DNSR_Shadows_KernelWeight(float i) {
#define KERNEL_WEIGHT(i) (exp(-3.0 * float(i * i) / ((KERNEL_RADIUS + 1.0) * (KERNEL_RADIUS + 1.0))))

    // Statically initialize kernel_weights_sum
    float kernel_weights_sum = 0;
    kernel_weights_sum += KERNEL_WEIGHT(0);
    for (int c = 1; c <= KERNEL_RADIUS; ++c) {
        kernel_weights_sum += 2 * KERNEL_WEIGHT(c); // Add other half of the kernel to the sum
    }
    float inv_kernel_weights_sum = rcp(kernel_weights_sum);

    // The only runtime code in this function
    return KERNEL_WEIGHT(i) * inv_kernel_weights_sum;
}

void FFX_DNSR_Shadows_AccumulateMoments(float value, float weight, inout float moments) {
    // We get value from the horizontal neighborhood calculations. Thus, it's both mean and variance due to using one sample per pixel
    moments += value * weight;
}

// The horizontal part of a 17x17 local neighborhood kernel
float FFX_DNSR_Shadows_HorizontalNeighborhood(ivec2 did) {
    const ivec2 base_did = did;

    // Prevent vertical out of bounds access
    if ((base_did.y < 0) || (base_did.y >= FFX_DNSR_Shadows_GetBufferDimensions().y))
        return 0;

    const uvec2 tile_index = FFX_DNSR_Shadows_GetTileIndexFromPixelPosition(base_did);
    const uint linear_tile_index = FFX_DNSR_Shadows_LinearTileIndex(tile_index, FFX_DNSR_Shadows_GetBufferDimensions().x);

    const int left_tile_index = int(linear_tile_index - 1);
    const int center_tile_index = int(linear_tile_index);
    const int right_tile_index = int(linear_tile_index + 1);

    bool is_first_tile_in_row = tile_index.x == 0;
    bool is_last_tile_in_row = tile_index.x == (FFX_DNSR_Shadows_RoundedDivide(FFX_DNSR_Shadows_GetBufferDimensions().x, 8) - 1);

    uint left_tile = 0;
    if (!is_first_tile_in_row)
        left_tile = FFX_DNSR_Shadows_ReadRaytracedShadowMask(left_tile_index);
    uint center_tile = FFX_DNSR_Shadows_ReadRaytracedShadowMask(center_tile_index);
    uint right_tile = 0;
    if (!is_last_tile_in_row)
        right_tile = FFX_DNSR_Shadows_ReadRaytracedShadowMask(right_tile_index);

    // Construct a single uint with the lowest 17bits containing the horizontal part of the local neighborhood.

    // First extract the 8 bits of our row in each of the neighboring tiles
    const uint row_base_index = (did.y % 4) * 8;
    const uint left = (left_tile >> row_base_index) & 0xFF;
    const uint center = (center_tile >> row_base_index) & 0xFF;
    const uint right = (right_tile >> row_base_index) & 0xFF;

    // Combine them into a single mask containting [left, center, right] from least significant to most significant bit
    uint neighborhood = left | (center << 8) | (right << 16);

    // Make sure our pixel is at bit position 9 to get the highest contribution from the filter kernel
    const uint bit_index_in_row = (did.x % 8);
    neighborhood = neighborhood >> bit_index_in_row; // Shift out bits to the right, so the center bit ends up at bit 9.

    float moment = 0.0; // For one sample per pixel this is both, mean and variance

    // First 8 bits up to the center pixel
    uint mask;
    int i;
    for (i = 0; i < 8; ++i) {
        mask = 1u << i;
        moment += select((mask & neighborhood) != 0, FFX_DNSR_Shadows_KernelWeight(8 - i), 0);
    }

    // Center pixel
    mask = 1u << 8;
    moment += select((mask & neighborhood) != 0, FFX_DNSR_Shadows_KernelWeight(0), 0);

    // Last 8 bits
    for (i = 1; i <= 8; ++i) {
        mask = 1u << (8 + i);
        moment += select((mask & neighborhood) != 0, FFX_DNSR_Shadows_KernelWeight(i), 0);
    }

    return moment;
}

shared float g_FFX_DNSR_Shadows_neighborhood[8][24];

float FFX_DNSR_Shadows_ComputeLocalNeighborhood(ivec2 did, ivec2 gtid) {
    float local_neighborhood = 0;

    float upper = FFX_DNSR_Shadows_HorizontalNeighborhood(ivec2(did.x, did.y - 8));
    float center = FFX_DNSR_Shadows_HorizontalNeighborhood(ivec2(did.x, did.y));
    float lower = FFX_DNSR_Shadows_HorizontalNeighborhood(ivec2(did.x, did.y + 8));

    g_FFX_DNSR_Shadows_neighborhood[gtid.x][gtid.y] = upper;
    g_FFX_DNSR_Shadows_neighborhood[gtid.x][gtid.y + 8] = center;
    g_FFX_DNSR_Shadows_neighborhood[gtid.x][gtid.y + 16] = lower;

    barrier();

    // First combine the own values.
    // KERNEL_RADIUS pixels up is own upper and KERNEL_RADIUS pixels down is own lower value
    FFX_DNSR_Shadows_AccumulateMoments(center, FFX_DNSR_Shadows_KernelWeight(0), local_neighborhood);
    FFX_DNSR_Shadows_AccumulateMoments(upper, FFX_DNSR_Shadows_KernelWeight(KERNEL_RADIUS), local_neighborhood);
    FFX_DNSR_Shadows_AccumulateMoments(lower, FFX_DNSR_Shadows_KernelWeight(KERNEL_RADIUS), local_neighborhood);

    // Then read the neighboring values.
    for (int i = 1; i < KERNEL_RADIUS; ++i) {
        float upper_value = g_FFX_DNSR_Shadows_neighborhood[gtid.x][8 + gtid.y - i];
        float lower_value = g_FFX_DNSR_Shadows_neighborhood[gtid.x][8 + gtid.y + i];
        float weight = FFX_DNSR_Shadows_KernelWeight(i);
        FFX_DNSR_Shadows_AccumulateMoments(upper_value, weight, local_neighborhood);
        FFX_DNSR_Shadows_AccumulateMoments(lower_value, weight, local_neighborhood);
    }

    return local_neighborhood;
}

void FFX_DNSR_Shadows_WriteTileMetaData(uvec2 gid, uvec2 gtid, bool is_cleared, bool all_in_light) {
    if (all(equal(gtid, uvec2(0)))) {
        uint light_mask = select(all_in_light, TILE_META_DATA_LIGHT_MASK, 0u);
        uint clear_mask = select(is_cleared, TILE_META_DATA_CLEAR_MASK, 0u);
        uint mask = light_mask | clear_mask;
        FFX_DNSR_Shadows_WriteMetadata(gid.y * FFX_DNSR_Shadows_RoundedDivide(FFX_DNSR_Shadows_GetBufferDimensions().x, 8) + gid.x, mask);
    }
}

void FFX_DNSR_Shadows_ClearTargets(uvec2 did, uvec2 gtid, uvec2 gid, float shadow_value, bool is_shadow_receiver, bool all_in_light) {
    FFX_DNSR_Shadows_WriteTileMetaData(gid, gtid, true, all_in_light);
    FFX_DNSR_Shadows_WriteReprojectionResults(did, vec2(shadow_value, 0)); // mean, variance

    // Tom: The original count for receivers here was 1, but this causes
    // any previously fully lit tiles stand out as they enter the penumbra
    // due to their different convergence rate.
    // By using a value > 1 here, the pixels are considered (partially) converged.
    float temporal_sample_count = select(is_shadow_receiver, 8, 0);

    FFX_DNSR_Shadows_WriteMoments(did, vec4(shadow_value, 0, temporal_sample_count, shadow_value)); // mean, variance, temporal sample count, local neighborhood
}

#include <utils/safety.glsl>

void FFX_DNSR_Shadows_TileClassification(uint group_index, uvec2 gid) {
    uvec2 gtid = FFX_DNSR_Shadows_RemapLane8x8(group_index); // Make sure we can use the QuadReadAcross intrinsics to access a 2x2 region.
    uvec2 did = gid * 8 + gtid;

    bool is_shadow_receiver = FFX_DNSR_Shadows_IsShadowReciever(did);

    bool skip_sky = FFX_DNSR_Shadows_ThreadGroupAllTrue(!is_shadow_receiver);
    if (skip_sky) {
        // We have to set all resources of the tile we skipped to sensible values as neighboring active denoiser tiles might want to read them.
        FFX_DNSR_Shadows_ClearTargets(did, gtid, gid, 0, is_shadow_receiver, false);
        return;
    }

    bool all_in_light = false;
    bool all_in_shadow = false;
    FFX_DNSR_Shadows_SearchSpatialRegion(gid, all_in_light, all_in_shadow);
    float shadow_value = select(all_in_light, 1, 0); // Either all_in_light or all_in_shadow must be true, otherwise we would not skip the tile.

    bool can_skip = all_in_light || all_in_shadow;
    // We have to append the entire tile if there is a single lane that we can't skip
    bool skip_tile = FFX_DNSR_Shadows_ThreadGroupAllTrue(can_skip);
    if (skip_tile) {
        // We have to set all resources of the tile we skipped to sensible values as neighboring active denoiser tiles might want to read them.
        FFX_DNSR_Shadows_ClearTargets(did, gtid, gid, shadow_value, is_shadow_receiver, all_in_light);
        return;
    }

    FFX_DNSR_Shadows_WriteTileMetaData(gid, gtid, false, false);

    float depth = FFX_DNSR_Shadows_ReadDepth(did);
    // const vec2 velocity = FFX_DNSR_Shadows_GetClosestVelocity(did.xy, depth); // Must happen before we deactivate lanes
    const vec4 reproj = safeTexelFetch(reprojection_tex, ivec2(did.xy), 0);
    const float local_neighborhood = FFX_DNSR_Shadows_ComputeLocalNeighborhood(ivec2(did), ivec2(gtid));

    const vec2 texel_size = FFX_DNSR_Shadows_GetInvBufferDimensions();
    const vec2 uv = (did.xy + 0.5f) * texel_size;
    // const vec2 history_uv = uv - velocity;
    const vec2 history_uv = uv + reproj.xy;
    const ivec2 history_pos = ivec2(history_uv * FFX_DNSR_Shadows_GetBufferDimensions());

    const uvec2 tile_index = FFX_DNSR_Shadows_GetTileIndexFromPixelPosition(did);
    const uint linear_tile_index = FFX_DNSR_Shadows_LinearTileIndex(tile_index, FFX_DNSR_Shadows_GetBufferDimensions().x);

    const uint shadow_tile = FFX_DNSR_Shadows_ReadRaytracedShadowMask(linear_tile_index);

    vec4 moments_current = vec4(0);
    float variance = 0;
    float shadow_clamped = 0;
    if (is_shadow_receiver) // do not process sky pixels
    {
#if 0
            bool hit_light = shadow_tile & FFX_DNSR_Shadows_GetBitMaskFromPixelPosition(did);
            float shadow_current = select(hit_light, 1.0, 0.0);
#else
        float shadow_current = FFX_DNSR_Shadows_HitsLight(did);
#endif

        const uint quad_reproj_valid_packed = uint(reproj.z * 15.0 + 0.5);
        const vec4 quad_reproj_valid = vec4(notEqual((uvec4(quad_reproj_valid_packed) & uvec4(1, 2, 4, 8)), uvec4(0)));

        vec4 previous_moments;

        // Perform moments and variance calculations
        {
            // bool is_disoccluded = FFX_DNSR_Shadows_IsDisoccluded(did, depth, velocity);
            bool is_disoccluded = dot(quad_reproj_valid, 1.0.xxxx) < 4.0;
            previous_moments = select(is_disoccluded, vec4(0.0f, 0.0f, 0.0f, 0.0f) // Can't trust previous moments on disocclusion
                                      ,
                                      FFX_DNSR_Shadows_ReadPreviousMomentsBuffer(history_uv));

            const float old_m = previous_moments.x;
            const float old_s = previous_moments.y;
            const float sample_count = previous_moments.z + 1.0f;
            const float new_m = mix(old_m, shadow_current, 1.0 / sample_count);
            const float new_s = mix(old_s, (shadow_current - old_m) * (shadow_current - new_m), 1.0 / sample_count);

            variance = new_s;
            moments_current = vec4(new_m, new_s, sample_count, local_neighborhood);
        }

        // Retrieve local neighborhood and reproject
        {
            float mean = local_neighborhood;
            float spatial_variance = local_neighborhood;

            spatial_variance = max(spatial_variance - mean * mean, 0.0f);

            const float n_deviations = 0.5;
            // const float n_deviations = 1.0;

            // Compute the clamping bounding box
            const float std_deviation = sqrt(spatial_variance);
            const float nmin = mean - n_deviations * std_deviation;
            const float nmax = mean + n_deviations * std_deviation;

            // Clamp reprojected sample to local neighborhood
            float shadow_previous = shadow_current;
            if (!FFX_DNSR_Shadows_IsFirstFrame()) {
                shadow_previous = FFX_DNSR_Shadows_ReadHistory(history_uv);
            }

            // Reduce history weighting
            const float sigma = 2.0f;
            const float temporal_discontinuity = (previous_moments.w - moments_current.w) / max(0.5f * std_deviation, 0.001f);
            const float sample_counter_damper = exp(-temporal_discontinuity * temporal_discontinuity / sigma);

            // Tom: scaling by too low a value causes all sorts of artifacts,
            // e.g. the edge of a soft shadow moving away becomes overly bright.
            moments_current.z *= max(0.5, sample_counter_damper);

            // shadow_clamped = clamp(shadow_previous, nmin, nmax);
            // shadow_clamped = shadow_previous;
            shadow_clamped = soft_color_clamp(
                shadow_current,
                shadow_previous,
                mean,
                // std_deviation * clamp(sample_counter_damper, 0.1, 1.0)
                std_deviation * 0.5);

            // Boost variance on first frames
            if (moments_current.z < 16.0f) {
                const float variance_boost = max(16.0f - moments_current.z, 1.0f);
                variance = max(variance, spatial_variance);
                variance *= variance_boost;
            }

            // Tom: Boost spatial filtering upon change
            // Note: Doesn't seem to help much
            // variance *= 1 + smoothstep(0.4, 1.0, temporal_discontinuity) * 10;
        }

        // Perform the temporal blend

        // Tom: unclear whata the previous temporal weight calculation was doing.
        // Replaced with a linear blend.
        shadow_clamped = mix(shadow_clamped, shadow_current, 1.0 / max(1.0, moments_current.z));
    }

    // Output the results of the temporal pass
    FFX_DNSR_Shadows_WriteReprojectionResults(did.xy, vec2(shadow_clamped, variance));
    FFX_DNSR_Shadows_WriteMoments(did.xy, moments_current);
}
