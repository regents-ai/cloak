"""Functional checks of the owner's agent tasks in a serving guest (decision
12 in docs/plan.md): the guest's runner runs Pi 1.3.0 in the reference
wrapper (bubblewrap, then torsocks) as the agent user, Pi's model requests go
to the guest's door port and over vsock to the Mac, and everything else Pi
and its tools open goes through the guest's Tor port, which has no other way
out: the guest has no network device.

cloak-host --serve stands in for the app. With --door it carries each
door-port connection to a stand-in for the app's door (guest_boot.py), which answers as
the door does, with the answers in tests/door_answers.json; with --runner it
takes the tasks. That file also holds Pi's two requests in the first check,
as captured on 14 November 2026. DoorGuestTests checks the real door against
both: it gives these answers, byte for byte but for the order of keys, and
takes these requests as Pi sends them; the first check here fails if Pi's
requests stop having those headers and fields. tor is the stand-in (fake_tor.py), which notes and refuses every
connection, so nothing leaves the Mac and no model is asked anything.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_task_path.py

Each check boots the guest once.
"""

import json
import re
import socket
import threading
import time

from guest_boot import ANSWERS, MODEL, Serving, box_pass, events, outputs, task, wait_for


def test_pi_takes_the_doors_answers_and_runs_its_tool_through_tor(tmp_path):
    """One task: the door's answer is a tool call, Pi runs the tool in the
    sandbox, sends its result back, and ends with the door's final answer.
    In the tool, curl under torsocks reaches the Tor port and nothing else;
    without torsocks it reaches nothing."""
    serving = Serving(tmp_path)
    try:
        presented = box_pass()
        serving.door.plans[presented] = ["tool", "final"]
        started = time.monotonic()
        ran = serving.run(task("Run the checks, then say they ran.", "s-1", presented))
        took = time.monotonic() - started
    finally:
        serving.close()

    assert ran[-1] == {"exited": {"status": 0, "signalled": False}}, ran
    assert all(set(e) in ({"output"}, {"error"}, {"exited"}) for e in ran), ran
    seen = outputs(ran)
    assert seen[0]["type"] == "session"
    ended = [e for e in seen if e["type"] == "tool_execution_end"]
    assert [e["toolName"] for e in ended] == ["bash"]
    result = ended[0]["result"]["content"][0]["text"]
    finals = [e["message"] for e in seen if e["type"] == "message_end" and e["message"]["role"] == "assistant"]
    assert [part["text"] for part in finals[-1]["content"] if part["type"] == "text"] == ["The checks ran."]

    # The tool ran in the sandbox, as the agent user, in the conversation's workspace.
    assert "pid1 bwrap in /workspace as 1005" in result, result
    # Under torsocks, curl reached the Tor port, which refused it; without
    # torsocks it reached nothing, and the stand-in tor saw no more.
    torsocks = int(re.search(r"torsocks curl exit (\d+)", result).group(1))
    bypass = int(re.search(r"bypass curl exit (\d+)", result).group(1))
    assert torsocks != 0 and bypass != 0, result
    assert "Network is unreachable" in result, result
    assert [r["destination"] for r in serving.routes()].count("192.0.2.1:80") == 1, serving.routes()

    # Pi's two requests: the task, then the tool's result.
    asked = serving.door.asked(presented)
    assert [r["line"] for r in asked] == ["POST /v1/chat/completions HTTP/1.1"] * 2
    first, second = (json.loads(r["body"]) for r in asked)
    assert first["model"] == second["model"] == MODEL and first["stream"] is True
    assert "bash" in [t["function"]["name"] for t in first["tools"]]
    assert first["messages"][-1] == {"role": "user", "content": [{"type": "text", "text": "Run the checks, then say they ran."}]}
    replies = [m for m in second["messages"] if m["role"] == "tool"]
    assert [m["tool_call_id"] for m in replies] == ["call_tool"]
    assert "torsocks curl exit" in json.dumps(replies[0]["content"])
    # Pi sends what DoorGuestTests shows the door takes: its requests as
    # captured in tests/door_answers.json, with the same headers and fields.
    captured = ANSWERS["requests"]
    sent = [[name for name, _ in r["headers"] if name not in ("host", "content-type", "content-length", "authorization")]
            for r in asked]
    assert sent == [[name for name, _ in captured["headers"]]] * 2
    assert [set(first), set(second)] == [set(json.loads(captured["first"])), set(json.loads(captured["second"]))]

    memory = {name: int(kb) for name, kb in re.findall(r"^(MemTotal|MemFree|MemAvailable|Shmem):\s+(\d+) kB", result, re.M)}
    resident = re.findall(r"^/proc/\d+/status:Name:\s+(\S+)\n/proc/\d+/status:VmRSS:\s+(\d+) kB", result, re.M)
    print(json.dumps({"seconds": round(took, 1), "memory_kb": memory, "rss_kb": resident}))


def test_a_task_ends_with_its_connection_and_conversations_run_side_by_side(tmp_path):
    """A task whose tool holds two connections to the door, one of them from a
    process in a session of its own, ends with every process in its sandbox
    within seconds of its connection closing. While it runs, another task in
    its conversation is refused, a task in another conversation runs to its
    end, and requests that do not read are refused; after it, the
    conversation's next task continues its session."""
    serving = Serving(tmp_path)
    try:
        holding, other = box_pass(), box_pass()
        serving.door.plans[holding] = ["hold"]
        serving.door.plans[other] = ["final"]
        held = serving.start(task("Hold two connections.", "s-a", holding))
        # Its events are read as they come, as the app reads them.
        rest: list[dict] = []
        reader = threading.Thread(target=lambda: rest.extend(events(held)))
        reader.start()
        wait_for(lambda: len(serving.door.silent()) == 2, 600, "the tool did not hold its connections")
        connections = serving.door.silent()

        assert serving.run(task("Something else.", "s-a", holding)) == [{"failed": "busy"}]
        for refused in [task("Hi.", "../s-a", holding), task(" \n\ufeff", "s-b", holding),
                        task("Hi.", "s-b", "cloak-nope"), task("Hi.", "s-b", holding, model="a\nb")]:
            assert serving.run(refused) == [{"failed": "invalid"}], refused

        beside = serving.run(task("Say they ran.", "s-c", other))
        assert beside[-1] == {"exited": {"status": 0, "signalled": False}}, beside
        assert serving.door.silent() == connections

        held.shutdown(socket.SHUT_WR)
        ending = time.monotonic()
        wait_for(lambda: all(c["closed"] is not None for c in connections), 30, "the task's processes outlived it")
        took = max(c["closed"] for c in connections) - ending
        assert took < 5, took
        # Ended by its connection, the task has no exit to send.
        reader.join(30)
        assert not reader.is_alive()
        assert rest and all(set(e) in ({"output"}, {"error"}) for e in rest), rest

        serving.door.plans[holding] = ["final"]
        continued = serving.run(task("Now say they ran.", "s-a", holding))
        assert continued[-1] == {"exited": {"status": 0, "signalled": False}}, continued
        last = json.loads(serving.door.asked(holding)[-1]["body"])
        said = [part["text"] for m in last["messages"] if m["role"] == "user" for part in m["content"]]
        assert said[0] == "Hold two connections." and said[-1] == "Now say they ran.", said
    finally:
        serving.close()
    print(json.dumps({"held_closed_within_s": round(took, 2)}))
