#pragma once

#include <shared/core.inl>

struct IndirectDrawParams {
    u32 vertex_count;
    u32 instance_count;
    u32 first_vertex;
    u32 first_instance;
};

struct Camera {
    f32mat4x4 proj_mat;
    f32mat3x3 rot_mat, prev_rot_mat;
    f32vec3 pos, prev_pos;
    f32 tan_half_fov;
    f32 prev_tan_half_fov;
    f32 focal_dist;
};

struct Player {
    Camera cam;
    f32vec3 pos, vel;
    f32vec3 rot;
    f32vec3 forward, lateral;
    f32 max_speed;
};

struct BrushInput {
    f32vec3 pos;
    f32vec3 prev_pos;
};

struct VoxelChunkUpdateInfo {
    u32vec3 i;
    u32 flags;
    BrushInput brush_input;
};

struct VoxelWorld {
    VoxelChunkUpdateInfo chunk_update_infos[MAX_CHUNK_UPDATES_PER_FRAME];
    u32 chunk_update_n;
};

struct ChunkWorkItem {
    u32vec3 i;
    u32 brush_id;
    BrushInput brush_input;

    u32 children_finished[16];
};

struct ChunkThreadPoolState {
    u32 total_jobs_ran;
    u32 queue_index;

    u32 work_items_l0_queued;
    u32 work_items_l0_dispatch_y;
    u32 work_items_l0_dispatch_z;

    u32 work_items_l1_queued;
    u32 work_items_l1_dispatch_y;
    u32 work_items_l1_dispatch_z;

    u32 work_items_l0_completed;
    u32 work_items_l0_uncompleted;
    ChunkWorkItem chunk_work_items_l0[2][MAX_CHUNK_WORK_ITEMS_L0];

    u32 work_items_l1_completed;
    u32 work_items_l1_uncompleted;
    ChunkWorkItem chunk_work_items_l1[2][MAX_CHUNK_WORK_ITEMS_L1];
};

struct GpuIndirectDispatch {
    u32vec3 chunk_edit_dispatch;
    u32vec3 subchunk_x2x4_dispatch;
    u32vec3 subchunk_x8up_dispatch;
};

struct BrushState {
    u32 initial_frame;
    f32vec3 initial_ray;
    u32 is_editing;
};

struct VoxelParticlesState {
    u32vec3 simulation_dispatch;
    IndirectDrawParams draw_params;
};
struct SimulatedVoxelParticle {
    f32vec3 pos;
    f32 duration_alive;
    f32vec3 vel;
    u32 voxel_data;
    u32 flags;
};
DAXA_DECL_BUFFER_PTR(SimulatedVoxelParticle)

struct GpuGlobals {
    Player player;
    BrushInput brush_input;
    BrushState brush_state;
    VoxelWorld voxel_world;
    GpuIndirectDispatch indirect_dispatch;
    ChunkThreadPoolState chunk_thread_pool_state;
    VoxelParticlesState voxel_particles_state;
    u32 padding[10];
};
DAXA_DECL_BUFFER_PTR(GpuGlobals)

struct GpuSettings {
    f32 fov;
    f32 sensitivity;

    u32 log2_chunks_per_axis;
};
DAXA_DECL_BUFFER_PTR(GpuSettings)
