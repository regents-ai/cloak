"""Runs one zkapi-clientd config command in the trial container under a
terminal, logs what it prints, and answers its questions only when a go file
exists. Each question is answered at most once.

usage: drive.py LOG RULES_JSON -- docker args...
RULES_JSON: list of {"when": text, "go": path, "send": text}
"""
import json, os, pty, re, select, sys

log_path, rules = sys.argv[1], json.loads(sys.argv[2])
command = sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
seen = b""
pending = []
with open(log_path, "ab", buffering=0) as log:
    while True:
        ready, _, _ = select.select([fd], [], [], 1)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            log.write(data)
            seen += data
            for rule in list(rules):
                if rule["when"].encode() in seen:
                    rules.remove(rule)
                    pending.append(rule)
                    log.write(("\n[drive] waiting for " + rule["go"] + "\n").encode())
        for rule in list(pending):
            if os.path.exists(rule["go"]):
                pending.remove(rule)
                if "max_fee" in rule:
                    # Answer only while the last fee shown is under the cap.
                    fees = re.findall(rb"Maximum network fee: ([0-9.]+) ETH", seen)
                    if not fees or float(fees[-1]) > rule["max_fee"]:
                        log.write(b"\n[drive] fee over the cap; not answered\n")
                        continue
                    seen = b""
                    rules.append(rule)
                with open(rule["go"]) as f:
                    text = f.read().strip() if rule.get("from_go") else rule["send"]
                os.write(fd, (text + "\r").encode())
                log.write(b"\n[drive] answered\n")
                seen = b""
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            log.write(("\n[drive] exit " + str(os.waitstatus_to_exitcode(status)) + "\n").encode())
            break
