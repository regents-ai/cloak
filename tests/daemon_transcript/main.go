// Command cloak-daemon-transcript runs the daemon's own transcript over a
// conversation's requests, for the app's door tests
// (app/Tests/CloakTests/DoorTests.swift). It is built inside the pinned
// zkapi-clientd module with go build -overlay, which adds this file, so it
// can call internal/rewriter as the daemon does: one Transcript takes each
// request in turn, and its rewrites go to a loopback server that answers
// each text in upper case.
//
// Each line of standard input is a JSON array of request bodies, one
// conversation; each line of standard output is a JSON array with, for each
// request, {"ok": <whether the daemon took it>, "messages": <its messages as
// they would be sent>, "asked": <the texts of each rewrite it asked for, in
// order>}.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
)

type result struct {
	OK       bool              `json:"ok"`
	Messages []json.RawMessage `json:"messages"`
	Asked    [][]string        `json:"asked"`
}

func main() {
	lines := bufio.NewScanner(os.Stdin)
	lines.Buffer(make([]byte, 4<<20), 4<<20)
	out := json.NewEncoder(os.Stdout)
	for lines.Scan() {
		var bodies []json.RawMessage
		if err := json.Unmarshal(lines.Bytes(), &bodies); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		if err := out.Encode(run(bodies)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}
	if err := lines.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func run(bodies []json.RawMessage) []result {
	var asked [][]string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		var input struct {
			Texts []string `json:"texts"`
		}
		if json.NewDecoder(r.Body).Decode(&request) != nil || len(request.Messages) != 2 ||
			json.Unmarshal([]byte(request.Messages[1].Content), &input) != nil {
			http.Error(w, "unreadable", http.StatusBadRequest)
			return
		}
		asked = append(asked, input.Texts)
		upper := make([]string, len(input.Texts))
		for i, text := range input.Texts {
			upper[i] = strings.ToUpper(text)
		}
		content, _ := json.Marshal(map[string]any{"texts": upper})
		reply, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{
			"finish_reason": "stop", "message": map[string]any{"role": "assistant", "content": string(content)}}}})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(reply)
	}))
	defer server.Close()
	var transcript rewriter.Transcript
	results := []result{}
	for _, body := range bodies {
		asked = [][]string{}
		rewritten, _, err := transcript.Rewrite(context.Background(), body, rewriter.Config{URL: server.URL, Model: "worker"})
		r := result{OK: err == nil, Asked: asked}
		if err == nil {
			var request struct {
				Messages []json.RawMessage `json:"messages"`
			}
			_ = json.Unmarshal(rewritten, &request)
			r.Messages = request.Messages
		}
		results = append(results, r)
	}
	return results
}
