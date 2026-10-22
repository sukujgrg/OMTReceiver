#include "../Vendor/libvmx/src/thread_tasks.h"
#include <atomic>
#include <chrono>
#include <future>
#include <memory>

using namespace std::chrono_literals;

namespace {
struct WorkerFixture {
    ThreadTask worker;
    std::promise<void> firstEntered, secondEntered, joinFinished, destroyFinished;
    std::promise<void> releaseFirstPromise, releaseSecondPromise;
    std::shared_future<void> releaseFirst = releaseFirstPromise.get_future().share();
    std::shared_future<void> releaseSecond = releaseSecondPromise.get_future().share();
    std::atomic<int> accepted{0}, rejected{0};
};

// Promise gates control the ordering. Deadlock failures retain the fixture in
// the blocked, detached worker rather than hanging test cleanup or releasing
// its callback context. A successful run joins and destroys every worker.
bool nestedTasksAndJoin() {
    auto state = std::make_shared<WorkerFixture>();
    auto first = state->firstEntered.get_future();
    auto second = state->secondEntered.get_future();
    auto joined = state->joinFinished.get_future();
    state->worker.Initialize();
    state->worker.Push([state] {
        state->firstEntered.set_value();
        state->releaseFirst.wait();
        state->worker.Push([state] {
            state->secondEntered.set_value();
            state->releaseSecond.wait();
        });
    });
    bool firstReady = first.wait_for(2s) == std::future_status::ready;
    std::thread([state] { state->worker.Join(); state->joinFinished.set_value(); }).detach();
    state->releaseFirstPromise.set_value();
    bool secondReady = second.wait_for(2s) == std::future_status::ready;
    state->worker.complete.notify_all(); // A wake does not imply task completion.
    bool joinedTooSoon = joined.wait_for(0s) == std::future_status::ready;
    state->releaseSecondPromise.set_value();
    bool didJoin = joined.wait_for(2s) == std::future_status::ready;
    if (didJoin) state->worker.Destroy();
    return firstReady && secondReady && !joinedTooSoon && didJoin;
}

bool stopDrainsAdmittedWorkAndClosesAdmission() {
    auto state = std::make_shared<WorkerFixture>();
    auto entered = state->firstEntered.get_future();
    auto destroyed = state->destroyFinished.get_future();
    state->worker.Initialize();
    state->worker.Push([state] {
        state->firstEntered.set_value(); state->releaseFirst.wait();
    });
    state->worker.Push([state] { ++state->accepted; });
    bool enteredReady = entered.wait_for(2s) == std::future_status::ready;
    std::thread([state] { state->worker.Destroy(); state->destroyFinished.set_value(); }).detach();
    std::unique_lock<std::mutex> lock(state->worker.mtx, std::defer_lock);
    auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!lock.try_lock() && std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
    bool admissionClosed = lock.owns_lock()
        && state->worker.cv.wait_for(lock, 2s, [&] { return !state->worker.running; });
    if (lock.owns_lock()) lock.unlock();
    if (admissionClosed) state->worker.Push([state] { ++state->rejected; });
    state->releaseFirstPromise.set_value();
    bool didDestroy = destroyed.wait_for(2s) == std::future_status::ready;
    return enteredReady && admissionClosed && didDestroy && state->accepted == 1 && state->rejected == 0;
}

bool idleRetirementAndReconnect() {
    for (int i = 0; i < 250; ++i) {
        ThreadTask worker;
        worker.Initialize(); worker.Destroy();
        worker.Initialize();
        std::atomic<int> finished{0};
        worker.Push([&] { ++finished; });
        worker.Join(); worker.Destroy();
        if (finished != 1) return false;
    }
    return true;
}
}

#if defined(OMT_VMX_STANDALONE_TEST)
int main() {
    return nestedTasksAndJoin() && stopDrainsAdmittedWorkAndClosesAdmission() && idleRetirementAndReconnect() ? 0 : 1;
}
#else
#import <XCTest/XCTest.h>
@interface ReceiverCodecThreadTests : XCTestCase
@end
@implementation ReceiverCodecThreadTests
- (void)testJoinWaitsForNestedAndInFlightSliceWork { XCTAssertTrue(nestedTasksAndJoin()); }
- (void)testStopDrainsAcceptedWorkBeforeClosingCodec { XCTAssertTrue(stopDrainsAdmittedWorkAndClosesAdmission()); }
- (void)testIdleCodecWorkerRetirementAndReconnect { XCTAssertTrue(idleRetirementAndReconnect()); }
@end
#endif
