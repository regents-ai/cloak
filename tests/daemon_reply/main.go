// Command cloak-daemon-reply judges worker replies with the daemon's own code,
// for tests/test_llama_worker.py and the app's tests
// (app/Tests/CloakTests/RewriteTests.swift). It is built inside the pinned
// zkapi-clientd module with go build -overlay, which adds this file, so it
// can call internal/rewriter as the daemon does: Select builds the daemon's
// draft for the texts, and Draft.Rewrite sends it to a loopback server that
// answers with the worker's reply, byte for byte. Every check on the reply is
// the daemon's own.
//
// Each line of standard input is {"texts": [...], "reply": <the worker's
// reply body, base64>}; each line of standard output is {"accepted": <whether
// the daemon accepts the reply>, "request": <the request body the daemon
// sent, base64>, "texts": <the texts it took from the reply, or null>}.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
)

type verdict struct {
	Accepted bool     `json:"accepted"`
	Request  []byte   `json:"request"`
	Texts    []string `json:"texts"`
}

func main() {
	lines := bufio.NewScanner(os.Stdin)
	lines.Buffer(make([]byte, 4<<20), 4<<20)
	out := json.NewEncoder(os.Stdout)
	for lines.Scan() {
		var c struct {
			Texts []string `json:"texts"`
			Reply []byte   `json:"reply"`
		}
		if err := json.Unmarshal(lines.Bytes(), &c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		if err := out.Encode(judge(c.Texts, c.Reply)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}
	if err := lines.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func judge(texts []string, reply []byte) verdict {
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
	var request []byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		request, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(reply)
	}))
	defer server.Close()
	_, notice, err := draft.Rewrite(context.Background(), rewriter.Config{URL: server.URL, Model: "worker"})
	return verdict{Accepted: err == nil, Request: request, Texts: notice.Texts}
}
