// The guest's daemon: the pinned zkapi-clientd command package with this one
// file added by go build -overlay. Every other file stays the daemon's own,
// but for internal/rewriter/rewriter.go and internal/server/server.go, which
// the overlay replaces with copies carrying Cloak's input limit and deadline
// (guest/daemon/*.patch, docs/plan.md decision 6).
// Its init runs before the daemon's main and never returns to it.
//
// It starts the daemon's local inference API exactly as serveSnapshot does
// (the same zkConfig, zkapi.Client, zkInference error mapping, server.API and
// request logging) with the reference settings: Tor routing at
// tor://127.0.0.1:9050 and the rewriter on the guest adapter. What serve does
// first and this does not, because its prerequisites are absent: the funding
// check and deposit, the wallet companion and its connect proxy, the
// deployment check, cover traffic, and the session and settlement monitors.
// With no companion, every request stops after its rewrite and its Tor route
// (or at the route, with the checks' stand-in tor): no key is acquired, so
// nothing reaches a target model. No fallback exists here, as in the daemon.
//
// Usage: cloak-daemon <rewriter model> <rewriter key file>
// It prints "ready" on standard output once it listens, and nothing else
// there; its log goes to standard error.
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/config"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/server"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/zkapi"
)

const (
	guestTorRoute    = "tor://127.0.0.1:9050"
	guestRewriterURL = "http://127.0.0.1:8012/v1"
)

func init() {
	logger := log.New(os.Stderr, "zkapi-clientd ", log.LstdFlags)
	if err := cloakGuestServe(os.Args[1:], logger); err != nil {
		logger.Printf("ERROR %s", err)
		os.Exit(1)
	}
	os.Exit(0)
}

func cloakGuestServe(args []string, logger *log.Logger) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: cloak-daemon <rewriter model> <rewriter key file>")
	}
	key, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	c, err := config.Default()
	if err != nil {
		return err
	}
	c.RelayURL = guestTorRoute
	c.Rewriter = rewriter.Config{URL: guestRewriterURL, Model: args[0], APIKey: strings.TrimSpace(string(key))}
	if err := config.Validate(c); err != nil {
		return err
	}

	// From here on, as serveSnapshot.
	client, err := relay.NewClient(c.RelayURL)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", c.Listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	wallet, err := zkapi.New(zkConfig(c, client))
	if err != nil {
		return err
	}
	api, err := server.New(zkInference{wallet}, c.APIKey, c.Concurrency)
	if err != nil {
		return err
	}
	api.DefaultModel = c.DefaultModel
	api.RewriterNotice = c.Rewriter.Notice
	api.RequireAPIKey = c.RequireAPIKey
	api.Status = server.ServiceStatus{Backend: c.Backend, Network: c.ZKAPI.Network, RequestBudgetPolicy: "model"}
	life := context.Background()
	httpServer := &http.Server{Handler: server.LogRequests(api, logger), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: time.Minute, MaxHeaderBytes: 32 << 10, ErrorLog: log.New(io.Discard, "", 0), BaseContext: func(net.Listener) context.Context { return life }}
	logger.Printf("zkAPI client %s listening at http://%s/v1 (%s); Tor required (conversation isolation; IsolateSOCKSAuth required on Tor)", version, c.Listen, c.Backend)
	fmt.Println("ready")
	return httpServer.Serve(listener)
}
