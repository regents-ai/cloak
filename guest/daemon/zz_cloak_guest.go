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
// tor://127.0.0.1:9050 and the rewriter on the guest adapter. It starts the
// daemon's own cover traffic as serve does (startServeCover, for the life of
// the API, closed and joined when it ends), with the rate and concurrency of
// Cloak's one cover list, /etc/cloak/cover.json in the image
// (reference/cover.json), and destinations from the list's pool of URLs. A
// pool of more than the 16 the daemon takes gives it 16, distinct and picked
// at random at each start; those 16 serve until the next start. An empty
// pool is cover off, the daemon's own cleared setting. Every URL in the
// pool, picked or not, must pass the daemon's own cover validation, one to
// an entry and none listed twice, or the daemon does not start. The picked
// URLs are not logged, as the daemon logs no destinations. What serve does
// first and this does not, because its prerequisites are absent: the funding
// check and deposit, the wallet companion and its connect proxy, the
// deployment check, and the session and settlement monitors.
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
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/config"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/cover"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/rewriter"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/server"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/zkapi"
)

const (
	guestTorRoute    = "tor://127.0.0.1:9050"
	guestRewriterURL = "http://127.0.0.1:8012/v1"
	guestCoverList   = "/etc/cloak/cover.json"
	// The most cover URLs the daemon takes (cover.Config.Validate).
	guestCoverMost = 16
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
	c.Cover, err = guestCover(guestCoverList)
	if err != nil {
		return err
	}
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
	// In serving mode (/etc/cloak/serve), Pi talks to the Mac's door rather than
	// this daemon; require the daemon's random in-memory API key so a sandboxed
	// agent on loopback cannot trigger host rewrites while cover traffic runs.
	if _, err := os.Stat("/etc/cloak/serve"); err == nil {
		api.RequireAPIKey = true
	} else {
		api.RequireAPIKey = c.RequireAPIKey
	}
	api.Status = server.ServiceStatus{Backend: c.Backend, Network: c.ZKAPI.Network, RequestBudgetPolicy: "model"}
	// The mark the daemon's own serve sets (runConfiguredServe): this is the
	// long-running API, which owns cover traffic.
	life := context.WithValue(context.Background(), coverServeKey{}, true)
	stopCover, err := startServeCover(life, c, logger)
	if err != nil {
		return err
	}
	defer stopCover()
	httpServer := &http.Server{Handler: server.LogRequests(api, logger), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: time.Minute, MaxHeaderBytes: 32 << 10, ErrorLog: log.New(io.Discard, "", 0), BaseContext: func(net.Listener) context.Context { return life }}
	logger.Printf("zkAPI client %s listening at http://%s/v1 (%s); Tor required (conversation isolation; IsolateSOCKSAuth required on Tor)", version, c.Listen, c.Backend)
	fmt.Println("ready")
	return httpServer.Serve(listener)
}

// guestCover reads Cloak's cover list, {"urls": [...], "rate": <requests a
// second>, "concurrency": <requests at once>}, as the daemon's own cover
// settings. No URLs is the zero setting, cover off, as `config
// --clear-cover` leaves it. Otherwise each URL, with the list's rate and
// concurrency, must pass the daemon's own cover validation on its own, hold
// no space (so one entry is one URL to the daemon) and be listed once (so
// none is twice as likely); then coverPick chooses the URLs the daemon gets.
func guestCover(path string) (cover.Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return cover.Config{}, err
	}
	defer file.Close()
	var list struct {
		URLs        []string `json:"urls"`
		Rate        float64  `json:"rate"`
		Concurrency int      `json:"concurrency"`
	}
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&list); err != nil {
		return cover.Config{}, fmt.Errorf("cover list %s: %w", path, err)
	}
	if len(list.URLs) == 0 {
		return cover.Config{}, nil
	}
	listed := make(map[string]bool, len(list.URLs))
	for _, address := range list.URLs {
		one := cover.Config{Rate: list.Rate, Concurrency: list.Concurrency, URLs: address}
		if err := one.Validate(guestTorRoute); err != nil {
			return cover.Config{}, fmt.Errorf("cover list %s: %w", path, err)
		}
		if strings.ContainsFunc(address, unicode.IsSpace) {
			return cover.Config{}, fmt.Errorf("cover list %s: a URL holds a space", path)
		}
		if listed[address] {
			return cover.Config{}, fmt.Errorf("cover list %s: a URL is listed twice", path)
		}
		listed[address] = true
	}
	urls, err := coverPick(list.URLs)
	if err != nil {
		return cover.Config{}, err
	}
	return cover.Config{Rate: list.Rate, Concurrency: list.Concurrency, URLs: strings.Join(urls, " ")}, nil
}

// coverPick returns the whole pool when it holds no more than the daemon
// takes. Otherwise it returns guestCoverMost of its URLs, distinct and each
// as likely as any other, by a partial Fisher-Yates shuffle of a copy drawn
// from crypto/rand, the source of the daemon's own cover randomness.
func coverPick(pool []string) ([]string, error) {
	if len(pool) <= guestCoverMost {
		return pool, nil
	}
	picked := slices.Clone(pool)
	for i := range guestCoverMost {
		j, err := rand.Int(rand.Reader, big.NewInt(int64(len(picked)-i)))
		if err != nil {
			return nil, err
		}
		k := i + int(j.Int64())
		picked[i], picked[k] = picked[k], picked[i]
	}
	return picked[:guestCoverMost], nil
}
