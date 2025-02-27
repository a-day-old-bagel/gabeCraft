#pragma once

struct GLFWwindow;
struct ImFont;

#include "app_settings.hpp"
#include <imgui.h>
#include <chrono>
#include <filesystem>
#include <thread>
#include <mutex>
#include <fmt/format.h>

#include <gvox/gvox.h>

#define INVALID_GAME_ACTION (-1)

struct AppUi {
    struct Console {
        char input_buffer[256]{};
        std::vector<std::string> items;
        std::vector<const char *> commands;
        std::vector<char *> history;
        int history_pos{-1};
        ImGuiTextFilter filter;
        bool auto_scroll{true};
        bool scroll_to_bottom{false};
        std::shared_ptr<std::mutex> items_mtx = std::make_shared<std::mutex>();
        inline static Console *s_instance = nullptr;

        Console();
        ~Console();

        void clear_log();
        void add_log(std::string const &str);
        void draw(const char *title, bool *p_open);
        void exec_command(const char *command_line);
        int on_text_edit(ImGuiInputTextCallbackData *data);
    };

    struct Pass {
        std::string name;
        daxa::TaskImageView task_image_id;
        daxa_u32 type;
    };

    struct DebugDisplayProvider {
        virtual ~DebugDisplayProvider() = default;
        virtual void add_ui() = 0;
    };

    struct DebugDisplay {
        struct GpuResourceInfo {
            std::string type;
            std::string name;
            size_t size;
        };
        std::vector<GpuResourceInfo> gpu_resource_infos;
        std::vector<DebugDisplayProvider *> providers;
        std::vector<Pass> passes{};
        uint32_t selected_pass{};
        std::string selected_pass_name{};

        inline static DebugDisplay *s_instance = nullptr;

        DebugDisplay();
        ~DebugDisplay();
    };

    using Clock = std::chrono::high_resolution_clock;

    AppUi(GLFWwindow *glfw_window_ptr);
    ~AppUi();

    AppSettings settings;

    GLFWwindow *glfw_window_ptr;
    ImFont *mono_font = nullptr;
    ImFont *menu_font = nullptr;

    std::array<float, 200> full_frametimes = {};
    std::array<float, 200> cpu_frametimes = {};
    daxa_u64 frametime_rotation_index = 0;

    daxa_f32 debug_menu_size{};
    char const *debug_gpu_name{};

    bool needs_saving = false;
    Clock::time_point last_save_time{};
    Console console{};
    DebugDisplay debug_display{};

    daxa_u32 conflict_resolution_mode = 0;
    daxa_i32 new_key_id{};
    daxa_i32 limbo_action_index = INVALID_GAME_ACTION;
    daxa_i32 limbo_key_index = GLFW_KEY_LAST + 1;
    bool limbo_is_button = false;

    bool paused = true;
    bool show_settings = false;
    bool should_run_startup = true;
    bool should_recreate_voxel_buffers = true;
    bool autosave_override = false;
    bool should_upload_seed_data = true;
    bool should_hotload_shaders = false;
    bool should_regenerate_sky = true;

    bool should_record_task_graph = false;

    static inline constexpr std::array<char const *, 5> resolution_scale_options = {
        "33%",
        "50%",
        "67%",
        "75%",
        "100%",
    };
    static inline constexpr std::array<float, 5> resolution_scale_values = {
        0.33333333f,
        0.50f,
        0.66666667f,
        0.75f,
        1.00f,
    };
    daxa_f32 render_res_scl = 1.0f;

    bool should_upload_gvox_model = false;
    std::filesystem::path gvox_model_path;
    GvoxRegionRange gvox_region_range{
        .offset = {0, 0, 0},
        .extent = {256, 256, 256},
        // .offset = {-932, -663, -72},
        // .extent = {1932, 1167, 635},
        // .offset = {-70, 108, 150},
        // .extent = {32, 32, 16},
    };

    std::filesystem::path data_directory;

    void rescale_ui();
    void update(daxa_f32 delta_time, daxa_f32 cpu_delta_time);

    void toggle_pause();
    void toggle_debug();
    void toggle_help();
    void toggle_console();

  private:
    void settings_ui();
    void settings_controls_ui();
    void settings_passes_ui();
};
