import CloakHost
@testable import CloakSupervisor
import Foundation
import Testing

/// The details of a message being written (decision 13): the strict reading
/// of the worker's reply, the message a submit makes from what is picked,
/// the first pick fixing the details shown, and the request itself, through
/// a real relay to tests/fake_worker.py.
@Suite(.serialized)
struct DetailsTests {
    static let content = #"""
        {"details":[{"kind":"options","label":"Ages","question":"How old are the kids?","many":true,"options":[{"mark":"👶","text":"Under 5"},{"mark":"","text":"5 to 12"},{"mark":"🎒","text":"Teens"}]},\#
        {"kind":"range","label":"Budget","question":"What is the budget?","low":500,"high":5000,"unit":"USD"},\#
        {"kind":"colors","label":"Colors","question":"Which colours?","colors":[{"name":"Coral","hex":"#ff7f50"},{"name":"Deep Teal","hex":"#008080"},{"name":"Slate","hex":"#708090"}]},\#
        {"kind":"pad","label":"Tone","question":"What tone?","left":"Formal","right":"Casual","top":"Short","bottom":"Long"}]}
        """#

    static let details = [
        Detail(label: "Ages", question: "How old are the kids?", picker: .options([
            .init(mark: "👶", text: "Under 5"), .init(mark: "", text: "5 to 12"), .init(mark: "🎒", text: "Teens"),
        ], many: true)),
        Detail(label: "Budget", question: "What is the budget?", picker: .range(low: 500, high: 5000, unit: "USD")),
        Detail(label: "Colors", question: "Which colours?", picker: .colors([
            .init(name: "Coral", hex: "#ff7f50"), .init(name: "Deep Teal", hex: "#008080"), .init(name: "Slate", hex: "#708090"),
        ])),
        Detail(label: "Tone", question: "What tone?", picker: .pad(left: "Formal", right: "Casual", top: "Short", bottom: "Long")),
    ]

    static func reply(_ content: String, finish: String = "stop", choices: Int = 1) -> [UInt8] {
        let choice: [String: Any] = ["index": 0, "finish_reason": finish, "message": ["role": "assistant", "content": content]]
        let body: [String: Any] = ["object": "chat.completion", "choices": Array(repeating: choice, count: choices)]
        return Array(try! JSONSerialization.data(withJSONObject: body))
    }

    // MARK: The reply

    @Test func aReplyWithEachKindOfDetailIsRead() {
        #expect(!Self.content.contains("\n"))
        #expect(Details.details(status: 200, body: Self.reply(Self.content)) == Self.details)
        #expect(Details.details(status: 200, body: Self.reply(#"{"details":[]}"#)) == [])
    }

    /// Each changes the content above in one way the grammar or the reader
    /// does not allow.
    @Test(arguments: [
        (#""bottom":"Long"}]}"#, #""bottom":"Long"}],"note":"x"}"#),
        (#""label":"Ages""#, #""label":"Ages of kids""#),
        (#""label":"Ages""#, #""label":"Extraordinary""#),
        (#""label":"Ages""#, #""label":"Ages ""#),
        (#""question":"What tone?""#, #""question":""#),
        (#""question":"What tone?""#, #""question":"\#(String(repeating: "a", count: 61))""#),
        (#""question":"What tone?""#, #""question":" What tone?""#),
        (#""question":"What tone?""#, #""question":"What\ntone?""#),
        (#""many":true,"#, #""many":"yes","#),
        (#""text":"Teens""#, #""text":"\#(String(repeating: "a", count: 33))""#),
        (#",{"mark":"","text":"5 to 12"},{"mark":"🎒","text":"Teens"}"#, ""),
        (#""mark":"👶""#, #""mark":"x""#),
        (#""mark":"👶""#, #""mark":"👶👶""#),
        (#""low":500"#, #""low":5000"#),
        (#""low":500"#, #""low":-1000000"#),
        (#""unit":"USD""#, #""unit":"US dollars each""#),
        (#""unit":"USD""#, #""unit":"USD","many":true"#),
        (##",{"name":"Slate","hex":"#708090"}"##, ""),
        (##""hex":"#ff7f50""##, ##""hex":"#FF7F50""##),
        (##""hex":"#ff7f50""##, ##""hex":"ff7f50""##),
        (##""hex":"#ff7f50""##, ##""hex":"#ff7f5""##),
        (#","bottom":"Long""#, ""),
        (#""kind":"pad""#, #""kind":"slider""#),
        (#""left":"Formal""#, #""left":"Very formal indeed""#),
    ])
    func aReplyOutsideTheGrammarIsRefused(_ part: String, _ changed: String) {
        let content = Self.content.replacingOccurrences(of: part, with: changed)
        #expect(content != Self.content)
        #expect(Details.details(status: 200, body: Self.reply(content)) == nil)
    }

    @Test func moreThanFourDetailsAreRefused() {
        let one = #"{"kind":"range","label":"Count","question":"How many?","low":1,"high":9,"unit":""}"#
        let five = #"{"details":["# + Array(repeating: one, count: 5).joined(separator: ",") + "]}"
        let four = #"{"details":["# + Array(repeating: one, count: 4).joined(separator: ",") + "]}"
        #expect(Details.details(status: 200, body: Self.reply(four))?.count == 4)
        #expect(Details.details(status: 200, body: Self.reply(five)) == nil)
    }

    @Test func aReplyThatDidNotStopOrIsNotOneChoiceIsRefused() {
        let content = #"{"details":[]}"#
        #expect(Details.details(status: 200, body: Self.reply(content, finish: "length")) == nil)
        #expect(Details.details(status: 200, body: Self.reply(content, choices: 2)) == nil)
        #expect(Details.details(status: 500, body: Self.reply(content)) == nil)
        #expect(Details.details(status: 200, body: Self.reply("```json\n" + content + "\n```")) == nil)
        #expect(Details.details(status: 200, body: Array("not json".utf8)) == nil)
    }

    // MARK: Picks

    @Test func untouchedDetailsAddNothing() {
        var picks = DetailPicks()
        picks.show(Self.details)
        #expect(picks.message("Plan a week in Japan with my kids.") == "Plan a week in Japan with my kids.")
    }

    @Test func eachPickIsALineAfterABlankLine() {
        var picks = DetailPicks()
        picks.show(Self.details)
        picks.pick(.options([2, 0]), at: 0)
        picks.pick(.range(low: 1000, high: 2500), at: 1)
        picks.pick(.color(1), at: 2)
        picks.pick(.pad(x: 1, y: -1), at: 3)
        #expect(picks.message("Plan a week in Japan with my kids.") == """
            Plan a week in Japan with my kids.

            Ages: Under 5, Teens
            Budget: 1000–2500 USD
            Colors: Deep Teal
            Tone: Short, Casual
            """)
    }

    @Test func aValueReadsAsItsDetailPutsIt() {
        let (ages, budget, tone) = (Self.details[0], Self.details[1], Self.details[3])
        let count = Detail(label: "Guests", question: "How many?", picker: .range(low: 2, high: 12, unit: ""))
        #expect(DetailPicks.value(of: .range(low: 3, high: 3), for: budget) == "3 USD")
        #expect(DetailPicks.value(of: .range(low: 3, high: 5), for: count) == "3–5")
        #expect(DetailPicks.value(of: .pad(x: -1, y: 0), for: tone) == "Formal")
        #expect(DetailPicks.value(of: .pad(x: 0, y: 1), for: tone) == "Long")
        #expect(DetailPicks.value(of: .pad(x: -1, y: 1), for: tone) == "Long, Formal")
        #expect(DetailPicks.value(of: .other("  about 3000 a week "), for: budget) == "about 3000 a week")
        #expect(DetailPicks.value(of: .other("Toddlers"), for: ages) == "Toddlers")
    }

    @Test func aClearedPickAddsNothing() {
        var picks = DetailPicks()
        picks.show(Self.details)
        picks.pick(.color(0), at: 2)
        picks.pick(.other("Grandparents too"), at: 0)
        picks.pick(nil, at: 2)
        #expect(picks.message("Plan it.") == "Plan it.\n\nAges: Grandparents too")
    }

    /// Until something is picked, each answer replaces the details shown;
    /// from the first pick, none does, even once that pick is cleared.
    @Test func theFirstPickFixesTheDetails() {
        let other = [Self.details[1]]
        var picks = DetailPicks()
        picks.show(Self.details)
        picks.show(other)
        #expect(picks.details == other && picks.picks == [nil] && !picks.fixed)
        picks.show(Self.details)
        picks.pick(.color(2), at: 2)
        picks.show(other)
        #expect(picks.details == Self.details && picks.fixed)
        picks.pick(nil, at: 2)
        picks.show(other)
        #expect(picks.details == Self.details && picks.picks.allSatisfy { $0 == nil } && picks.fixed)
    }

    @Test func aDraftOfFourWordsOrMoreIsAskedAbout() {
        #expect(!Details.enoughToAsk(""))
        #expect(!Details.enoughToAsk("   \n "))
        #expect(!Details.enoughToAsk("Plan a trip."))
        #expect(!Details.enoughToAsk("Plan a — trip!"))
        #expect(Details.enoughToAsk("Plan a trip there."))
        #expect(Details.enoughToAsk("来週の大阪出張のスケジュールを立ててください。"))
    }

    // MARK: The request

    @Test func theRequestIsTheDaemonsShapeWithTheDraft() throws {
        let request = Details.request(model: "small-lead-gguf-grammar", draft: "Plan a week <here> & \"there\".")
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(Set(object.keys) == ["max_tokens", "messages", "model", "stream", "temperature"])
        #expect(object["max_tokens"] as? Int == Details.maxTokens)
        #expect(object["stream"] as? Bool == false && object["temperature"] as? Int == 0)
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"] == Details.system)
        let user = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: String]
        #expect(user == ["draft": "Plan a week <here> & \"there\"."])
    }

    @Test func overTenThousandCharactersIsNeverSent() async throws {
        try await FakeWorker.with { worker async throws in
            let draft = "case:ok " + String(repeating: "é", count: 10_000 - 7)
            await #expect(throws: RewriteStop.tooLong(characters: 10_001)) {
                try await Details.run(draft, model: "worker", relay: worker.relay, deadline: .seconds(30))
            }
            #expect(worker.requests == 0)
        }
    }

    @Test func cancellingStopsTheWorker() async throws {
        try await FakeWorker.with { worker async throws in
            let call = Task { try await Details.run("case:hold plan a trip", model: "worker", relay: worker.relay, deadline: .seconds(30)) }
            try await worker.waitFor("1.json")
            call.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await call.value }
            #expect(worker.has("1.cancel"))
        }
    }

    @Test func pastTheDeadlineTheWorkerIsStopped() async throws {
        try await FakeWorker.with { worker async throws in
            await #expect(throws: RewriteStop.timedOut) {
                try await Details.run("case:hold plan a trip", model: "worker", relay: worker.relay, deadline: .milliseconds(500))
            }
            #expect(worker.has("1.cancel"))
        }
    }

    /// A rewrite asked for while a details request is at the worker stops
    /// that request, and is answered once the worker has.
    @Test func aDetailsRequestGivesWayToARewrite() async throws {
        try await FakeWorker.with { worker async throws in
            let details = Task { try await Details.run("case:hold plan a trip", model: "worker", relay: worker.relay, deadline: .seconds(30)) }
            try await worker.waitFor("1.json")
            #expect(try await worker.rewrite("case:ok say hello") == "CASE:OK SAY HELLO")
            await #expect(throws: RewriteStop.stopped) { try await details.value }
            #expect(worker.has("1.cancel"))
            #expect(worker.requests == 2)
        }
    }

    /// A rewrite at the worker is never stopped by a details request after
    /// it: that one waits its turn.
    @Test func aRewriteNeverGivesWay() async throws {
        try await FakeWorker.with { worker async throws in
            let rewrite = Task { try await worker.rewrite("case:hold say hello") }
            try await worker.waitFor("1.json")
            let details = Task { try await Details.run("case:hold plan a trip", model: "worker", relay: worker.relay, deadline: .seconds(30)) }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!worker.has("1.cancel"))
            #expect(worker.requests == 1)
            rewrite.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await rewrite.value }
            try await worker.waitFor("2.json")
            details.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await details.value }
        }
    }
}
