// Command cloak-daemon-reply judges worker replies with the daemon's own code,
// for tests/test_llama_worker.py. It is built inside the pinned zkapi-clientd
// module with go build -overlay, which adds this file, so it can call
// internal/rewriter as the daemon does: Select builds the daemon's draft for
// the texts, and Draft.Rewrite sends it to a loopback server that answers
// with the worker's reply, byte for byte. Every check on the reply is the
// daemon's own.
//
// Each line of standard input is {"texts": [...], "reply": <the worker's
// reply body, base64>}; each line of standard output is "accepted" or
// "refused".
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
)

func main() {
	lines := bufio.NewScanner(os.Stdin)
	lines.Buffer(make([]byte, 4<<20), 4<<20)
	for lines.Scan() {
		var c struct {
			Texts []string `json:"texts"`
			Reply []byte   `json:"reply"`
		}
		if err := json.Unmarshal(lines.Bytes(), &c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		fmt.Println(judge(c.Texts, c.Reply))
	}
	if err := lines.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func judge(texts []string, reply []byte) string {
	parts := make([]map[string]string, len(texts))
	for i, text := range texts {
		parts[i] = map[string]string{"type": "text", "text": text}
	}
	body, _ := json.Marshal(map[string]any{"messages": []any{map[string]any{"role": "user", "content": parts}}})
	draft, err := rewriter.Select(body)
	if err != nil || draft == nil {
		fmt.Fprintln(os.Stderr, "the daemon would not rewrite these texts")
		os.Exit(2)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(reply)
	}))
	defer server.Close()
	if _, _, err := draft.Rewrite(context.Background(), rewriter.Config{URL: server.URL, Model: "worker"}); err != nil {
		return "refused"
	}
	return "accepted"
}
