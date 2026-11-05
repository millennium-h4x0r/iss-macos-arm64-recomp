// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: guest memory for the GPU. Apple GPUs share memory with the CPU, so guest
// memory is the GPU's buffer: the game's direct memory heaps (TLG_UNIFIED_RANGE) and every other
// GPU mapping are wrapped in MTLBuffers without copying (newBufferWithBytesNoCopy), and shaders
// read and write the guest's bytes in place. Nothing is uploaded, downloaded or tracked.

#pragma once

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <utility>

#include "common/types.h"
#include "video_core/buffer_cache/buffer.h"

namespace AmdGpu {
struct Liverpool;
}

namespace Vulkan {
class Instance;
class Scheduler;
class Runtime;
} // namespace Vulkan

namespace VideoCore {

class TextureCache;

class BufferCache {
public:
    static constexpr u32 STREAM_BUFFER_SIZE = 64_MB;
    static constexpr u32 UTILITY_BUFFER_SIZE = 32_MB;

    explicit BufferCache(const Vulkan::Instance& instance, Vulkan::Scheduler& scheduler,
                         Vulkan::Runtime& runtime, AmdGpu::Liverpool* liverpool);
    ~BufferCache();

    /// The buffer holding [addr, addr + size) and the offset of addr in it. Guest memory outside
    /// every imported mapping is copied into the stream buffer (GPU writes there are lost).
    std::pair<const Buffer*, u64> ObtainBuffer(VAddr addr, u64 size, bool is_written);
    /// tlg diagnosis (TLG_LOG_WRITE_RACE=1): a command processor write (WRITE_DATA, ...) to
    /// guest pages that work in a command buffer the GPU has not finished reads. Metal reads
    /// guest memory when the GPU runs, so that work would see the new value early.
    static bool WriteRaceEnabled();
    void NoteCpuWrite(VAddr addr, u64 size, const char* what);

    std::pair<const Buffer*, u64> ObtainBufferForImage(VAddr addr, u64 size) {
        return ObtainBuffer(addr, size, false);
    }

    /// Whether [addr, addr + size) is guest memory the GPU uses in place.
    bool IsInPlace(VAddr addr, u64 size);

    /// A GPU mapping of guest memory: imported (page-aligned part) when it is outside the
    /// unified range.
    void MapMemory(VAddr addr, u64 size);
    void UnmapMemory(VAddr addr, u64 size);

    StreamBuffer& GetStreamBuffer() {
        return *stream_buffer;
    }
    /// Host-visible scratch (staging) buffer.
    StreamBuffer& GetUtilityBuffer() {
        return *utility_buffer;
    }

    /// Memory is shared: CPU writes need no merge.
    bool CpuWriteMerge(VAddr, const void*, int, u64) {
        return false;
    }

    /// Statistics: bindings outside imported memory since the last call.
    u64 TakeCopiedBindings() {
        return std::exchange(copied_bindings, 0);
    }

private:
    struct Import {
        VAddr end;
        std::unique_ptr<Buffer> buffer;
    };
    std::unique_ptr<Buffer> Wrap(VAddr addr, u64 size, const char* what);

    const Vulkan::Instance& instance;
    Vulkan::Scheduler& scheduler;
    Vulkan::Runtime& runtime;
    std::unique_ptr<StreamBuffer> stream_buffer;
    std::unique_ptr<StreamBuffer> utility_buffer;
    std::unique_ptr<Buffer> unified; ///< the direct memory heaps
    VAddr unified_base = 0;
    VAddr unified_end = 0;
    std::mutex imports_mutex;
    std::map<VAddr, Import> imports; ///< by start address
    /// tlg: the imports the last bindings found, read without imports_mutex (a seqlock; written
    /// and cleared under it, cleared on every change of imports). ObtainBuffer's lock was ~6% of
    /// the command processor thread.
    struct ImportHint {
        std::atomic<VAddr> start{0};
        std::atomic<VAddr> end{0};
        std::atomic<Buffer*> buffer{nullptr};
    };
    static constexpr u32 NumHints = 8;
    std::atomic<u32> hint_seq{0};
    ImportHint hints[NumHints];
    u32 hint_next = 0;
    Buffer* FindHint(VAddr addr, u64 size) const noexcept {
        const u32 seq = hint_seq.load(std::memory_order_acquire);
        if (seq & 1) {
            return nullptr;
        }
        Buffer* found = nullptr;
        for (const auto& h : hints) {
            Buffer* b = h.buffer.load(std::memory_order_relaxed);
            if (b && h.start.load(std::memory_order_relaxed) <= addr &&
                addr + size <= h.end.load(std::memory_order_relaxed)) {
                found = b;
                break;
            }
        }
        std::atomic_thread_fence(std::memory_order_acquire);
        return hint_seq.load(std::memory_order_relaxed) == seq ? found : nullptr;
    }
    /// Under imports_mutex.
    template <typename F>
    void WriteHints(F&& f) noexcept {
        const u32 seq = hint_seq.load(std::memory_order_relaxed);
        hint_seq.store(seq + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        f();
        hint_seq.store(seq + 2, std::memory_order_release);
    }
    void AddHint(VAddr start, VAddr end, Buffer* buffer) noexcept {
        WriteHints([&] {
            auto& h = hints[hint_next++ % NumHints];
            h.start.store(start, std::memory_order_relaxed);
            h.end.store(end, std::memory_order_relaxed);
            h.buffer.store(buffer, std::memory_order_relaxed);
        });
    }
    void ClearHints() noexcept {
        WriteHints([&] {
            for (auto& h : hints) {
                h.buffer.store(nullptr, std::memory_order_relaxed);
            }
        });
    }
    u64 copied_bindings = 0;
};

} // namespace VideoCore
