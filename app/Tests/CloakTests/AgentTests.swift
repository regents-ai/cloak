import CloakChat
import CloakHost
import Foundation
import Testing

/// A task's start, against a stand-in guest: its turn is under way from the
/// press while its model is read, a second press in the conversation
/// meanwhile is refused, and a task stopped, or whose model could not be
/// had, before it runs never asks the door for a pass or runs in the guest,
/// so it never spends.
@MainActor
@Suite
struct AgentTests {
    /// What the stand-in guest and door were asked for.
    final class Guest {
        var requests: [Runner.Request] = []
        var passes = 0
    }

    static let answer = Data(
        #"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Done."}]}}"#.utf8)

    let guest = Guest()

    var agent: Agent {
        Agent(parts: Agent.Parts(
            run: { [guest] request in
                guest.requests.append(request)
                return AsyncThrowingStream { events in
                    events.yield(.output(Self.answer))
                    events.finish()
                }
            },
            pass: { [guest] _, _ in
                guest.passes += 1
                return "pass"
            },
            reworded: { _ in nil }))
    }

    @Test func runsFromItsPressAndRefusesASecond() async throws {
        let agent = agent
        let id = UUID()
        let (models, model) = AsyncStream<String>.makeStream()
        let (kept, keep) = AsyncStream<Turn>.makeStream()
        var turns = kept.makeAsyncIterator()
        agent.run("List the files", in: id, paying: .zkapi, model: { () async throws(Agent.End) -> String in
            for await name in models { return name }
            throw .failed(nil)
        }, keep: { keep.yield($0) })
        let started = try #require(await turns.next())
        #expect(agent.runs[id]?.turn.id == started.id)

        agent.run("Again", in: id, paying: .zkapi, model: { "other" }, keep: { keep.yield($0) })
        #expect(agent.runs[id]?.turn.id == started.id)
        #expect(guest.requests.isEmpty)
        #expect(guest.passes == 0)

        model.yield("v-model")
        let ended = try #require(await turns.next())
        #expect(ended.id == started.id)
        #expect(ended.answer == "Done.")
        #expect(guest.requests.map(\.model) == ["v-model"])
        #expect(guest.requests.map(\.task) == ["List the files"])
        #expect(agent.runs[id] == nil)
    }

    @Test func stoppedWhileItsModelIsReadNeverRuns() async throws {
        let agent = agent
        let id = UUID()
        let (models, model) = AsyncStream<String>.makeStream()
        let (kept, keep) = AsyncStream<Turn>.makeStream()
        var turns = kept.makeAsyncIterator()
        agent.run("List the files", in: id, paying: .zkapi, model: { () async throws(Agent.End) -> String in
            for await name in models { return name }
            throw .failed(nil)
        }, keep: { keep.yield($0) })
        let started = try #require(await turns.next())
        agent.stop(id)
        let ended = try #require(await turns.next())
        #expect(ended.id == started.id)
        #expect(agent.ends[ended.id] == .stopped)
        #expect(guest.requests.isEmpty)
        #expect(guest.passes == 0)
        model.finish()
    }

    @Test func aModelNotHadEndsBeforeItRuns() async throws {
        let agent = agent
        let id = UUID()
        let (kept, keep) = AsyncStream<Turn>.makeStream()
        var turns = kept.makeAsyncIterator()
        agent.run("List the files", in: id, paying: .zkapi, model: { () async throws(Agent.End) -> String in
            throw .failed("why")
        }, keep: { keep.yield($0) })
        _ = await turns.next()
        let ended = try #require(await turns.next())
        #expect(agent.ends[ended.id] == .failed("why"))
        #expect(agent.runs[id] == nil)
        #expect(guest.requests.isEmpty)
        #expect(guest.passes == 0)
    }
}
