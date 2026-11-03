// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: command submission. A tick is one MTLCommandBuffer: CurrentTick() is the
// one being recorded, Flush() commits it, IsFree/Wait follow its completion. At most one encoder
// is open at a time (render, compute or blit).

#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>

#include "common/types.h"
#include "common/unique_function.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Vulkan {

class Instance;

class Scheduler {
public:
    explicit Scheduler(const Instance& instance, const char* name = "draw");
    ~Scheduler();

    Scheduler(const Scheduler&) = delete;
    Scheduler& operator=(const Scheduler&) = delete;

    /// The tick of the command buffer being recorded.
    [[nodiscard]] u64 CurrentTick() const noexcept {
        return current_tick.load(std::memory_order_acquire);
    }
    /// The last tick the GPU completed.
    [[nodiscard]] u64 CompletedTick() const noexcept {
        return completed_tick.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool IsFree(u64 tick) const noexcept {
        return CompletedTick() >= tick;
    }

    /// Commits the command buffer being recorded (when anything was recorded or deferred).
    void Flush();
    /// Flush and wait for everything submitted.
    void Finish();
    /// Waits for `tick`, committing the current command buffer when it is that tick.
    void Wait(u64 tick);

    /// Runs `func` on the recording thread once the current tick has completed (Flush and
    /// PopPendingOperations run due operations).
    void DeferOperation(Common::UniqueFunction<void>&& func);
    void DeferPriorityOperation(Common::UniqueFunction<void>&& func) {
        DeferOperation(std::move(func));
    }
    void PopPendingOperations();

    /// Runs `func` on the completion thread when the current tick has completed, in order with
    /// the other signals (guest labels written by the GPU's end-of-pipe events). The command
    /// buffer is committed when the signal is queued.
    void SignalOnCompletion(std::function<void()> func);
    /// Waits for every SignalOnCompletion function queued so far to have run.
    void WaitSignals();

    // Encoders (Objective-C objects as void*: id<MTL...CommandEncoder>, borrowed).
    void* CommandBuffer();
    /// Ends the open encoder.
    void EndEncoding();
    /// Ends a render encoder (other encoders stay open).
    void EndRendering();
    void* ComputeEncoder();
    void* BlitEncoder();
    /// The open render encoder, or null.
    void* CurrentRenderEncoder() const noexcept;
    /// Installs a render encoder created by the rasterizer (ends the open encoder first).
    void SetRenderEncoder(void* encoder, u64 pass_key);
    [[nodiscard]] u64 RenderPassKey() const noexcept {
        return render_pass_key;
    }
    [[nodiscard]] bool IsRendering() const noexcept {
        return render_pass_key != 0;
    }

    /// Encoders opened since the start (statistics).
    [[nodiscard]] u64 EncoderCount() const noexcept {
        return encoders;
    }

    // Vulkan renderer API kept for the shared code.
    void WaitHostCopies() {}
    bool IsRecordingDeferred() const noexcept {
        return false;
    }
    template <typename F>
    void RecordHostCopy(F&& func) {
        func();
    }

    struct Impl;
    Impl* impl_() noexcept {
        return impl.get();
    }

    static inline std::mutex submit_mutex;
    static inline std::atomic<u64> direct_recordings{0};

private:
    std::unique_ptr<Impl> impl;
    const char* name;
    std::atomic<u64> current_tick{1};
    std::atomic<u64> completed_tick{0};
    u64 render_pass_key = 0;
    u64 encoders = 0;
};

} // namespace Vulkan
