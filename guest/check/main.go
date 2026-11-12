// Command cloak-rewrite-check drives the daemon's own rewrite code inside the
// guest. It is built inside the pinned zkapi-clientd module (with go build
// -overlay, which leaves the daemon's files untouched) so it can call
// internal/rewriter exactly as the daemon's client does before target
// inference: Transcript.Rewrite with the saved rewriter settings. Every
// request, reply check, limit and deadline is the daemon's.
//
// Each line of the cases file is {"name", "body", "cancel_after_ms"}: body is
// a chat request as a local client sends it to the daemon, and a positive
// cancel_after_ms cancels the call that long after it starts, as a client
// disconnecting does. One JSON result per case is printed to standard output.
// Lines with an "agent" or "sandbox" field are cloak-agent-check's and are
// skipped.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
)

type testCase struct {
	Name          string          `json:"name"`
	Body          json.RawMessage `json:"body"`
	CancelAfterMs int             `json:"cancel_after_ms"`
	Agent         json.RawMessage `json:"agent"`
	Sandbox       json.RawMessage `json:"sandbox"`
}

type result struct {
	Name    string   `json:"name"`
	Outcome string   `json:"outcome"` // rewritten or stopped
	Error   string   `json:"error,omitempty"`
	Texts   []string `json:"texts,omitempty"`
	Seconds float64  `json:"seconds"`
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: cloak-rewrite-check <cases.jsonl> <model> <rewriter-key-file>")
		os.Exit(2)
	}
	key, err := os.ReadFile(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	config := rewriter.Config{URL: "http://127.0.0.1:8012/v1", Model: os.Args[2], APIKey: strings.TrimSpace(string(key))}
	if err := config.Validate(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	cases, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	lines := bufio.NewScanner(cases)
	lines.Buffer(make([]byte, 4<<20), 4<<20)
	out := json.NewEncoder(os.Stdout)
	for lines.Scan() {
		var c testCase
		if err := json.Unmarshal(lines.Bytes(), &c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		if c.Agent != nil || c.Sandbox != nil {
			continue
		}
		_ = out.Encode(run(c, config))
	}
	if err := lines.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func run(c testCase, config rewriter.Config) result {
	ctx, cancel := context.Background(), context.CancelFunc(func() {})
	if c.CancelAfterMs > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(c.CancelAfterMs)*time.Millisecond)
	}
	defer cancel()
	var transcript rewriter.Transcript
	started := time.Now()
	_, notice, err := transcript.Rewrite(ctx, c.Body, config)
	r := result{Name: c.Name, Seconds: time.Since(started).Seconds()}
	if err != nil {
		r.Outcome, r.Error = "stopped", err.Error()
		return r
	}
	r.Outcome = "rewritten"
	if notice != nil {
		r.Texts = notice.Texts
	}
	return r
}
