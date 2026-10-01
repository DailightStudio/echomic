#ifndef ECHOMIC_TRIPLE_BUFFER_H
#define ECHOMIC_TRIPLE_BUFFER_H

#include <atomic>
#include <cstdint>

// Lock-free single-producer/single-consumer triple buffer.
//
// A naive 2-slot "double buffer" (writer picks whichever slot isn't the
// currently-published index, writes it, then publishes) is NOT safe if the
// writer can publish more than once while the reader is still in the middle
// of reading: the writer's second write can land on the exact slot the
// reader loaded moments earlier but hasn't finished reading yet, producing a
// torn read. A triple buffer fixes this by giving the writer a slot the
// reader can never be holding: writer and reader each privately own one
// slot, and a third "middle" slot is atomically swapped between them --
// meaning the writer's *current* slot is always completely disjoint from
// whatever the reader is doing this instant.
//
// Writer (control/JNI thread): fill writeSlot() in place, then commit().
// Reader (audio thread): call readSlot() once per block and use the result;
// it swaps in the latest published data if there is any.
template <typename T>
class TripleBuffer {
public:
    TripleBuffer() {
        state_.store(encode(/*middle=*/2, /*hasNew=*/false), std::memory_order_relaxed);
    }

    T &writeSlot() { return slots_[writeIndex_]; }

    void commit() {
        uint8_t oldState = state_.load(std::memory_order_relaxed);
        uint8_t newState;
        do {
            newState = encode(writeIndex_, true);
        } while (!state_.compare_exchange_weak(oldState, newState,
                                                std::memory_order_release,
                                                std::memory_order_relaxed));
        writeIndex_ = middleOf(oldState);
    }

    const T &readSlot() {
        uint8_t oldState = state_.load(std::memory_order_acquire);
        if (hasNew(oldState)) {
            uint8_t newState;
            do {
                newState = encode(readIndex_, false);
            } while (!state_.compare_exchange_weak(oldState, newState,
                                                    std::memory_order_acq_rel,
                                                    std::memory_order_acquire));
            readIndex_ = middleOf(oldState);
        }
        return slots_[readIndex_];
    }

private:
    static uint8_t encode(int middleIdx, bool hasNewFlag) {
        return static_cast<uint8_t>((middleIdx & 0x3) | (hasNewFlag ? 0x4 : 0));
    }
    static int middleOf(uint8_t s) { return s & 0x3; }
    static bool hasNew(uint8_t s) { return (s & 0x4) != 0; }

    T slots_[3]{};
    std::atomic<uint8_t> state_;
    // Reader-private / writer-private slot indices (never touched by the
    // other side): start disjoint from the initial "middle" (slot 2).
    int readIndex_ = 0;
    int writeIndex_ = 1;
};

#endif  // ECHOMIC_TRIPLE_BUFFER_H
