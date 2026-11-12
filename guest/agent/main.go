// Command cloak-agent-check runs the guest's agent cases: Pi inside the
// reference wrapper (bubblewrap with torsocks, reference/wrapper/), as its own
// user, talking to the guest daemon's local API; and plain commands in the
// same sandbox, to see what the agent's process tree can reach. It stands in
// for the person at the keyboard and changes nothing on the path.
//
// Each line of the cases file with an "agent" or "sandbox" field is one case;
// other lines belong to cloak-rewrite-check and are skipped:
//
//	{"name": "...", "agent": {"prompt": "...", "continue": false}}
//	{"name": "...", "sandbox": ["sh", "-c", "..."]}
//
// An agent case runs `pi-paranoid WORKSPACE -p PROMPT` (with -c to continue
// Pi's last session). One JSON result per case goes to standard output, with
// the program's exit status and output, the daemon's log lines written during
// the case (content-free), and every connection made to the Tor port.
//
// The guest has no Tor. A route observer listens on the Tor port instead and
// refuses every request after reading it: it records the SOCKS identity each
// connection presents (as a short hash) and the destination asked for, and
// never connects anywhere. So a request still stops at Tor route preparation,
// as it would with Tor present and unable to reach the network.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	agentUID, agentGID = 1005, 1005
	agentHome          = "/home/agent"
	workspace          = "/home/agent/workspace"
	wrapper            = "/opt/cloak/wrapper"
	torPort            = "127.0.0.1:9050"
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
}

type routeAttempt struct {
	Identity    string `json:"identity"` // first 16 hex of sha256(user, 0, password); "none" without authentication
	Destination string `json:"destination"`
}

type result struct {
	Name    string         `json:"name"`
	Exit    int            `json:"exit"`
	Output  string         `json:"output"`
	Seconds float64        `json:"seconds"`
	Route   []routeAttempt `json:"route"`
	Daemon  []string       `json:"daemon"`
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
	if len(cases) == 0 {
		return
	}
	observer, err := observeRoute()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	out := json.NewEncoder(os.Stdout)
	for _, c := range cases {
		_ = out.Encode(run(c, observer))
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
		if c.Agent != nil && c.Sandbox != nil {
			return nil, fmt.Errorf("case %q is both an agent and a sandbox case", c.Name)
		}
		if c.Agent == nil && c.Sandbox == nil {
			continue
		}
		cases = append(cases, c)
	}
	return cases, lines.Err()
}

func run(c agentCase, observer *routeObserver) result {
	var args []string
	if c.Agent != nil {
		args = []string{wrapper + "/pi-paranoid", workspace, "-p", c.Agent.Prompt}
		if c.Agent.Continue {
			args = []string{wrapper + "/pi-paranoid", workspace, "-c", "-p", c.Agent.Prompt}
		}
	} else {
		args = append([]string{wrapper + "/sandbox", workspace}, c.Sandbox...)
	}
	logStart := fileSize(daemonLog)
	observer.take()
	ctx, cancel := context.WithTimeout(context.Background(), caseLimit)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = agentHome
	cmd.Env = []string{"HOME=" + agentHome, "PATH=/usr/bin", "TERM=dumb"}
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: agentUID, Gid: agentGID, Groups: []uint32{}}, Setsid: true}
	started := time.Now()
	output, _ := cmd.CombinedOutput()
	r := result{Name: c.Name, Exit: cmd.ProcessState.ExitCode(), Output: string(output), Seconds: time.Since(started).Seconds()}
	// The daemon writes its last log line just after it answers.
	time.Sleep(200 * time.Millisecond)
	r.Route = observer.take()
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

// routeObserver listens on the Tor port and refuses every SOCKS5 request.
type routeObserver struct {
	mu       sync.Mutex
	attempts []routeAttempt
}

func observeRoute() (*routeObserver, error) {
	listener, err := net.Listen("tcp", torPort)
	if err != nil {
		return nil, err
	}
	o := &routeObserver{}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go o.refuse(conn)
		}
	}()
	return o, nil
}

// take returns the attempts seen since the last call and forgets them.
func (o *routeObserver) take() []routeAttempt {
	o.mu.Lock()
	defer o.mu.Unlock()
	attempts := o.attempts
	o.attempts = nil
	if attempts == nil {
		attempts = []routeAttempt{}
	}
	return attempts
}

func (o *routeObserver) refuse(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	attempt := routeAttempt{Identity: "none"}
	defer func() {
		o.mu.Lock()
		o.attempts = append(o.attempts, attempt)
		o.mu.Unlock()
	}()
	in := bufio.NewReader(conn)
	// Greeting: version 5, the offered methods.
	head, err := readN(in, 2)
	if err != nil || head[0] != 5 {
		attempt.Destination = "not socks5"
		return
	}
	methods, err := readN(in, int(head[1]))
	if err != nil {
		return
	}
	if bytes.IndexByte(methods, 2) >= 0 {
		if _, err := conn.Write([]byte{5, 2}); err != nil {
			return
		}
		// RFC 1929: version 1, user, password.
		version, err := readN(in, 2)
		if err != nil || version[0] != 1 {
			return
		}
		user, err := readN(in, int(version[1]))
		if err != nil {
			return
		}
		size, err := readN(in, 1)
		if err != nil {
			return
		}
		password, err := readN(in, int(size[0]))
		if err != nil {
			return
		}
		digest := sha256.Sum256(append(append(user, 0), password...))
		attempt.Identity = hex.EncodeToString(digest[:8])
		if _, err := conn.Write([]byte{1, 0}); err != nil {
			return
		}
	} else if _, err := conn.Write([]byte{5, 0}); err != nil {
		return
	}
	// Request: version, command, reserved, address type, address, port.
	request, err := readN(in, 4)
	if err != nil {
		return
	}
	var host string
	switch request[3] {
	case 1:
		address, err := readN(in, 4)
		if err != nil {
			return
		}
		host = net.IP(address).String()
	case 3:
		size, err := readN(in, 1)
		if err != nil {
			return
		}
		name, err := readN(in, int(size[0]))
		if err != nil {
			return
		}
		host = string(name)
	case 4:
		address, err := readN(in, 16)
		if err != nil {
			return
		}
		host = net.IP(address).String()
	default:
		return
	}
	port, err := readN(in, 2)
	if err != nil {
		return
	}
	attempt.Destination = net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port))))
	// General failure: nothing is connected.
	_, _ = conn.Write([]byte{5, 1, 0, 1, 0, 0, 0, 0, 0, 0})
}

func readN(in io.Reader, n int) ([]byte, error) {
	buffer := make([]byte, n)
	_, err := io.ReadFull(in, buffer)
	return buffer, err
}
