// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: command submission. A tick is one MTLCommandBuffer: CurrentTick() is the
// one being recorded, Flush() commits it, IsFree/Wait follow its completion. At most one encoder
// is open at a time (render, compute or blit).
//
// Encoder thread (the draw scheduler; TLG_METAL_ENCODER_THREAD=0: off): the recording thread
// (the GPU command processor) records closures holding the Metal calls (mtl_scheduler_internal.h:
// Record, RecordRender, RecordCompute, RecordBlit, BeginRender); a thread of the scheduler runs
// them in order and owns the command buffers and encoders. The recording thread keeps the ticks,
// the deferred operations and a mirror of which kind of encoder is open. Off, the closures run
// at once on the recording thread.

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
    /// The SignalOnCompletion functions queued so far (a target for RunAfterSignals).
    [[nodiscard]] u64 SignalsQueued();
    /// The SignalOnCompletion functions that have run so far.
    [[nodiscard]] u64 SignalsDone();
    /// Waits until the first `target` SignalOnCompletion functions have run.
    void WaitSignalsUpTo(u64 target);
    /// Runs `func` once the first `target` SignalOnCompletion functions have run: now (on this
    /// thread) when they have, else on the completion thread right after them. Never waits.
    void RunAfterSignals(u64 target, std::function<void()> func);

    /// Ends the open encoder.
    void EndEncoding();
    /// Ends a render encoder (other encoders stay open).
    void EndRendering();
    [[nodiscard]] u64 RenderPassKey() const noexcept {
        return render_pass_key;
    }
    [[nodiscard]] bool IsRendering() const noexcept {
        return render_pass_key != 0;
    }

    /// tlg: TLG_METAL_ASYNC_COMPUTE=1 (no encoder thread then): the guest's compute queues
    /// record into a second Metal queue (lane 1) that runs beside the graphics one (lane 0), as
    /// on the console. Selecting a lane takes effect at the next command buffer or encoder (the
    /// other lane's open command buffer is committed then). Graphics command buffers wait for
    /// the compute work committed before them; compute does not wait for graphics (the guest's
    /// label waits order that).
    void SelectLane(int lane) noexcept;
    [[nodiscard]] static bool AsyncCompute() noexcept;
    /// tlg: TLG_METAL_ASYNC_COMPUTE=particles: only the guest's particle jobs (compute jobs that
    /// end with a GDS store, learnt by their shaders) go to the compute lane, where they
    /// complete within a few ms of their commit: the game reads their GDS counts right after
    /// their flags (written when recorded). The rest of the compute stays with graphics.
    [[nodiscard]] static bool ParticleLanes() noexcept;

    /// Encoders opened since the start, as recorded (a new value: a new encoder).
    [[nodiscard]] u64 EncoderCount() const noexcept {
        return encoders;
    }

    /// The recording side's mirror of the open encoder.
    enum class Kind : u8 { None, Render, Compute, Blit };
    [[nodiscard]] Kind OpenKind() const noexcept {
        return open_kind;
    }
    /// Records that an encoder of `kind` is used next (a new one when another kind is open).
    void UseEncoder(Kind kind, u64 pass_key = 0) noexcept {
        if (kind == Kind::Render) {
            open_kind = kind;
            render_pass_key = pass_key ? pass_key : 1;
            ++encoders;
            return;
        }
        if (open_kind != kind) {
            open_kind = kind;
            render_pass_key = 0;
            ++encoders;
        }
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
    Kind open_kind = Kind::None;
    int rec_lane = 0; ///< tlg: the lane selected on the recording side (SelectLane)
};

} // namespace Vulkan
