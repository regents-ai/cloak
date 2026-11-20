// cloak-pay, the guest's payer (docs/plan.md, "Payment in the guest:
// cloak-pay"): the mainnet zkapi-clientd command package
// (reference/src/zkapi-mainnet) with this file and zz_cloak_pay_linux.go
// added by go build -overlay. Every other file stays the daemon's own, but
// for internal/relay/relay.go, internal/relay/socks5.go and
// internal/zkapi/client.go, which the overlay replaces with copies patched by
// guest/pay/*.patch: Tor is the only route, every connection carries a Tor
// identity, the conversation's identity goes on the inference request alone,
// and the wallet client can hold a request until no settlement is unfinished.
//
// It serves the host only, over the guest's vsock port payPort, one request
// to a connection, in frames of a kind byte, a four-byte big-endian length
// and the payload, as the guest's sender does:
//
//	host:      R {"identity": "<64 hex>", "body": "<chat request, JSON>"}
//	cloak-pay: A {"status": <HTTP status>, "body": "<answer, JSON>"}
//
// The body is the Mac's request in OpenAI's chat shape, every user message
// already reworded there. It goes through the daemon's own inference API
// (internal/server) as a POST to /v1/chat/completions, and the answer is what
// that API gives: the provider's completion, or the daemon's error,
// {"error": {...}}. The identity is the conversation's Tor identity, its
// SOCKS user name. No key or wallet secret is in a frame.
//
// Requests reach the API one at a time, in the order their frames have been
// read in full. Each is held while the wallet reports an earlier request
// whose settlement is unfinished, this run's or one an earlier run left in
// the wallet's journal, and asks for its key once that settlement is done
// (WaitSettled, in client.patch). A host that hangs up first cancels its
// request, waiting or held, and nothing is sent or spent for it. A SIGTERM
// stops it as the daemon's own serve stops (run says how).
//
// It opens no TCP listener: the daemon's local API (127.0.0.1:8787), with its
// keyless loopback inference and its admin routes, is never started. The API
// is called in this process, with bearer authentication on, its key made at
// start and kept in memory, and no admin handler.
//
// Not yet (docs/release.md, the build order): the encrypted disk, and the
// companion, which nothing here starts. With no companion, every request
// stops at the daemon's companion check, before any key is asked for and
// before anything reaches Tor.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os/signal"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/config"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/server"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/zkapi"
)

const (
	// The guest's vsock port the host connects to; the sender's is 8020.
	payPort = 8021
	// The host's vsock address, VMADDR_CID_HOST.
	payHostCID  = 2
	payTorRoute = "tor://127.0.0.1:9050"
	payRequest  = 'R'
	payAnswer   = 'A'
	// The largest frame either side takes, as the sender's; the daemon's API
	// takes request bodies up to the same size.
	payMaxFrame = 16 << 20
)

// payConfig is the daemon's default configuration with Tor as its only route
// and a new provider key for every request (Sean, 18 November).
func payConfig() (config.Config, error) {
	c, err := config.Default()
	if err != nil {
		return config.Config{}, err
	}
	c.RelayURL = payTorRoute
	c.KeyReuseWindowSeconds = 0
	return c, config.Validate(c)
}

// pay is the daemon's inference API, called in this process.
type pay struct {
	api        http.Handler
	key        string
	logger     *log.Logger
	turns      payTurns
	background sync.WaitGroup // the daemon's session reporting and automatic settlement
}

// payInference is the daemon's zkInference with WaitSettled in front of each
// request: nothing asks for a key while the wallet reports a settlement
// unfinished. The API answers a hold cancelled by the host or a stop as it
// answers any cancelled request (408), and a wallet error from the hold as an
// error it does not map (502).
type payInference struct{ zkInference }

func (p payInference) Complete(ctx context.Context, body json.RawMessage) (*http.Response, error) {
	if err := p.Client.WaitSettled(ctx); err != nil {
		return nil, err
	}
	return p.zkInference.Complete(ctx, body)
}

// newPay builds the API as the daemon's serveSnapshot does, from the same
// relay client, zkConfig, zkapi.Client, zkInference error mapping, server.API
// and request log, but with the hold in front of the backend, bearer
// authentication on and no admin handler, and runs the daemon's session
// reporting and automatic settlement for the life of ctx.
func newPay(ctx context.Context, c config.Config, logger *log.Logger) (*pay, error) {
	client, err := relay.NewClient(c.RelayURL)
	if err != nil {
		return nil, err
	}
	wallet, err := zkapi.New(zkConfig(c, client))
	if err != nil {
		return nil, err
	}
	api, err := server.New(payInference{zkInference{wallet}}, c.APIKey, c.Concurrency)
	if err != nil {
		return nil, err
	}
	api.RequireAPIKey = true
	p := &pay{api: server.LogRequests(api, logger), key: c.APIKey, logger: logger}
	p.background.Add(2)
	go func() {
		defer p.background.Done()
		monitorSessions(ctx, logger, wallet, 5*time.Second)
	}()
	go func() {
		defer p.background.Done()
		runAutomaticSettlement(ctx, logger, wallet)
	}()
	return p, nil
}

// payLife is cloak-pay's life, which ends at a SIGTERM, the guest's stop.
func payLife() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGTERM)
}

// payListener is the guest's vsock port: Accept gives the next connection
// from the host, and Close ends an Accept waiting.
type payListener interface {
	Accept() (io.ReadWriteCloser, error)
	Close() error
}

// run serves each connection the listener gives in a goroutine of its own
// until ctx, payLife, ends. Then it takes no new request, and everything
// waiting or under way ends with ctx, as the daemon's own serve ends on a
// stop: a request waiting for its turn is closed unanswered, one held or
// waiting for its key is answered 408 with nothing spent, one cut during its
// answer gets none, and a settlement under way is cut and left in the
// wallet's journal, which the next run's first request waits on. It returns
// once every connection and the daemon's session reporting and automatic
// settlement have ended.
func (p *pay) run(ctx context.Context, listener payListener) error {
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	var conns sync.WaitGroup
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() == nil {
				return err
			}
			conns.Wait()
			p.background.Wait()
			return nil
		}
		conns.Add(1)
		go func() {
			defer conns.Done()
			defer conn.Close()
			if err := p.serve(ctx, conn); err != nil {
				p.logger.Printf("connection ended with no answer: %s", err)
			}
		}()
	}
}

// payFromHost is the accept rule: only the host may connect. A connection
// from anywhere else is closed unanswered, as the sender and runner do.
func payFromHost(cid uint32) bool { return cid == payHostCID }

// payIdentity is the sender's check of a conversation's identity: 32 bytes in
// hex.
func payIdentity(identity string) bool {
	decoded, err := hex.DecodeString(identity)
	return err == nil && len(decoded) == 32
}

type payAnswerFrame struct {
	Status int    `json:"status"`
	Body   string `json:"body"`
}

// The answer to a request frame that does not read, or whose identity is not
// 32 bytes in hex; nothing leaves for it.
var payRefused = payAnswerFrame{Status: http.StatusBadRequest,
	Body: `{"error":{"message":"The frame needs the request body and the conversation's identity, 64 hex characters.","type":"invalid_frame","code":"invalid_frame","param":null}}`}

// serve answers one connection's request. A request that reads waits for its
// turn, then goes to the API. A connection whose first frame is not a
// request, or whose answer breaks off, gets no answer. If the host closes the
// connection first, the request is cancelled, as the daemon's HTTP server
// cancels one whose client goes away: while it waits for its turn it leaves
// the queue, and in the API it ends before its key is asked for, if it has
// not been.
func (p *pay) serve(ctx context.Context, conn io.ReadWriter) error {
	kind, payload, err := readPayFrame(conn)
	if err != nil {
		return err
	}
	if kind != payRequest {
		return errors.New("the first frame is not a request")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		_, _ = conn.Read(make([]byte, 1))
		cancel()
	}()
	var request struct {
		Identity string `json:"identity"`
		Body     string `json:"body"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	answer := payRefused
	if decoder.Decode(&request) == nil && payIdentity(request.Identity) {
		end, err := p.turns.take(ctx)
		if err != nil {
			return err
		}
		answer, err = p.complete(ctx, request.Identity, request.Body)
		end()
		if err != nil {
			return err
		}
	}
	data, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return writePayFrame(conn, payAnswer, data)
}

// payTurns gives requests to the API one at a time, in the order they ask:
// the guest's own guarantee, whatever the daemon's slots allow.
type payTurns struct {
	mu    sync.Mutex
	queue []chan struct{} // in the order asked; the first holds the turn
}

// take waits for the caller's turn and returns the function that ends it. If
// ctx ends first, the caller leaves the queue and take returns ctx's error.
func (t *payTurns) take(ctx context.Context) (func(), error) {
	mine := make(chan struct{})
	t.mu.Lock()
	t.queue = append(t.queue, mine)
	if len(t.queue) == 1 {
		close(mine)
	}
	t.mu.Unlock()
	leave := func() {
		t.mu.Lock()
		defer t.mu.Unlock()
		i := slices.Index(t.queue, mine)
		t.queue = slices.Delete(t.queue, i, i+1)
		if i == 0 && len(t.queue) > 0 {
			close(t.queue[0])
		}
	}
	select {
	case <-mine:
		return leave, nil
	case <-ctx.Done():
		leave()
		return nil, ctx.Err()
	}
}

// complete posts the body to the API's chat route with the conversation's
// identity in its context and returns what the API wrote.
func (p *pay) complete(ctx context.Context, identity, body string) (answer payAnswerFrame, err error) {
	req, err := http.NewRequestWithContext(zkapi.WithConversation(ctx, identity), http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return payAnswerFrame{}, err
	}
	req.Header.Set("Authorization", "Bearer "+p.key)
	req.Header.Set("Content-Type", "application/json")
	w := &payWriter{header: http.Header{}}
	defer func() {
		// The API ends an answer whose provider stream broke off with
		// http.ErrAbortHandler, which net/http's server expects to recover.
		if r := recover(); r != nil {
			if r != http.ErrAbortHandler {
				panic(r)
			}
			err = errors.New("the answer broke off")
		}
	}()
	p.api.ServeHTTP(w, req)
	if w.over {
		return payAnswerFrame{}, errors.New("the answer is larger than a frame")
	}
	return payAnswerFrame{Status: w.status, Body: w.body.String()}, nil
}

// payWriter keeps what the API writes: its status, and its body up to a
// frame's size.
type payWriter struct {
	header http.Header
	status int
	body   bytes.Buffer
	over   bool
}

func (w *payWriter) Header() http.Header { return w.header }

func (w *payWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}

func (w *payWriter) Write(data []byte) (int, error) {
	w.WriteHeader(http.StatusOK)
	if w.body.Len()+len(data) > payMaxFrame {
		w.over = true
		return 0, errors.New("the answer is larger than a frame")
	}
	return w.body.Write(data)
}

// Flush lets the API's event streams through; the whole answer goes in one
// frame once the API returns.
func (w *payWriter) Flush() {}

func readPayFrame(r io.Reader) (byte, []byte, error) {
	var head [5]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(head[1:])
	if length > payMaxFrame {
		return 0, nil, errors.New("frame too large")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return head[0], payload, nil
}

func writePayFrame(w io.Writer, kind byte, payload []byte) error {
	if len(payload) > payMaxFrame {
		return errors.New("frame too large")
	}
	frame := make([]byte, 5, 5+len(payload))
	frame[0] = kind
	binary.BigEndian.PutUint32(frame[1:], uint32(len(payload)))
	_, err := w.Write(append(frame, payload...))
	return err
}
