// Command cloak-agent-check runs the guest's agent cases: Pi inside the
// reference wrapper (bubblewrap with torsocks, reference/wrapper/), as its own
// user, talking to the guest daemon's local API; plain commands in the same
// sandbox, to see what the agent's process tree can reach; and plain commands
// as the payer's user, outside the sandbox, standing in for the payer's
// programs on the payment disk. It stands in for the person at the keyboard
// and changes nothing on the path.
//
// Each line of the cases file with an "agent", "sandbox" or "pay" field is one
// case; other lines belong to cloak-rewrite-check and are skipped:
//
//	{"name": "...", "agent": {"prompt": "...", "continue": false}}
//	{"name": "...", "sandbox": ["sh", "-c", "..."]}
//	{"name": "...", "pay": ["sh", "-c", "..."]}
//
// An agent case runs `pi-paranoid WORKSPACE -p PROMPT` (with -c to continue
// Pi's last session). A pay case runs in the payer's home, the payment disk's
// mount point. One JSON result per case goes to standard output, with
// the program's exit status and output and the daemon's log lines written
// during the case (content-free). Connections to the Tor port go through the
// guest's Tor port to the host's tor, which the checks see from the host.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	agentUID, agentGID = 1005, 1005
	agentHome          = "/home/agent"
	workspace          = "/home/agent/workspace"
	wrapper            = "/opt/cloak/wrapper"
	payUID, payGID     = 1009, 1009
	payHome            = "/var/lib/cloak-pay"
	daemonLog          = "/run/cloak/daemon.log"
	caseLimit          = 10 * time.Minute
)

type agentCase struct {
	Name  string `json:"name"`
	Agent *struct {
		Prompt   string `json:"prompt"`
		Continue bool   `json:"continue"`
	} `json:"agent"`
	Sandbox []string `json:"sandbox"`
	Pay     []string `json:"pay"`
}

type result struct {
	Name    string   `json:"name"`
	Exit    int      `json:"exit"`
	Output  string   `json:"output"`
	Seconds float64  `json:"seconds"`
	Daemon  []string `json:"daemon"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: cloak-agent-check <cases.jsonl>")
		os.Exit(2)
	}
	cases, err := readCases(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	out := json.NewEncoder(os.Stdout)
	for _, c := range cases {
		_ = out.Encode(run(c))
	}
}

func readCases(path string) ([]agentCase, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	lines := bufio.NewScanner(file)
	lines.Buffer(make([]byte, 4<<20), 4<<20)
	var cases []agentCase
	for lines.Scan() {
		var c agentCase
		if err := json.Unmarshal(lines.Bytes(), &c); err != nil {
			return nil, err
		}
		kinds := 0
		for _, set := range []bool{c.Agent != nil, c.Sandbox != nil, c.Pay != nil} {
			if set {
				kinds++
			}
		}
		if kinds > 1 {
			return nil, fmt.Errorf("case %q is more than one kind of case", c.Name)
		}
		if kinds == 0 {
			continue
		}
		if c.Pay != nil && len(c.Pay) == 0 {
			return nil, fmt.Errorf("case %q has no pay command", c.Name)
		}
		cases = append(cases, c)
	}
	return cases, lines.Err()
}

func run(c agentCase) result {
	var args []string
	uid, gid, home := uint32(agentUID), uint32(agentGID), agentHome
	switch {
	case c.Agent != nil:
		args = []string{wrapper + "/pi-paranoid", workspace, "-p", c.Agent.Prompt}
		if c.Agent.Continue {
			args = []string{wrapper + "/pi-paranoid", workspace, "-c", "-p", c.Agent.Prompt}
		}
	case c.Sandbox != nil:
		args = append([]string{wrapper + "/sandbox", workspace}, c.Sandbox...)
	default:
		args = c.Pay
		uid, gid, home = payUID, payGID, payHome
	}
	logStart := fileSize(daemonLog)
	ctx, cancel := context.WithTimeout(context.Background(), caseLimit)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = home
	cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin", "TERM=dumb"}
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: gid, Groups: []uint32{}}, Setsid: true}
	started := time.Now()
	output, err := cmd.CombinedOutput()
	// A case that never started (the payer's home not mounted, say) says why.
	if cmd.ProcessState == nil {
		output = append(output, err.Error()...)
	}
	r := result{Name: c.Name, Exit: cmd.ProcessState.ExitCode(), Output: string(output), Seconds: time.Since(started).Seconds()}
	// The daemon writes its last log line just after it answers.
	time.Sleep(200 * time.Millisecond)
	r.Daemon = linesSince(daemonLog, logStart)
	return r
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

func linesSince(path string, offset int64) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil
	}
	data, _ := io.ReadAll(file)
	lines := []string{}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}
