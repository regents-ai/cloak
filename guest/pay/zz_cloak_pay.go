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
// It serves the host only, over the guest's vsock port payPort, one exchange
// to a connection, in frames of a kind byte, a four-byte big-endian length
// and the payload, as the guest's sender does (docs/zkapi-mac-side.md,
// section 1):
//
//	host:      R {"identity": "<64 hex>", "body": "<chat request, JSON>"}
//	cloak-pay: H {"held": true}, then H {"held": false}, only if held
//	cloak-pay: A {"status": <HTTP status>, "body": "<answer, JSON>"}
//
//	host:      C {"method": "GET" or "POST", "path": "<route>", "body": "<JSON, or empty>"}
//	cloak-pay: A {"status": <HTTP status>, "body": "<the route's answer>"}
//
//	host:      V {"chain": true or false}
//	cloak-pay: A {"status": <HTTP status>, "body": "<the deposit, JSON>"}
//
// An R's body is the Mac's request in OpenAI's chat shape, every user message
// already reworded there. It goes through the daemon's own inference API
// (internal/server) as a POST to /v1/chat/completions, and the answer is what
// that API gives: the provider's completion, or the daemon's error,
// {"error": {...}}. The identity is the conversation's Tor identity, its
// SOCKS user name.
//
// Requests reach the API one at a time, in the order their frames have been
// read in full. Each is held while the wallet reports an earlier request
// whose settlement is unfinished, this run's or one an earlier run left in
// the wallet's journal, and asks for its key once that settlement is done
// (WaitSettled, in client.patch); the H frames tell the host when the hold
// begins and ends. A host that hangs up first cancels its request, waiting
// or held, and nothing is sent or spent for it. A SIGTERM stops it as the
// daemon's own serve stops (run says how).
//
// A C calls one of the daemon's money routes, the exact methods and paths of
// payRoutes, and nothing else; a V reads the deposit: the wallet's note and
// settlement, and with "chain" the chain at one block (ReadChain, in
// zz_cloak_chain.go). Neither waits for a request's turn. No key, token or
// wallet secret is in a frame.
//
// The daemon's local API (127.0.0.1:8787), with its keyless loopback
// inference, is never started. The API is called in this process, with
// bearer authentication on and its key made at start and kept in memory. Its
// admin routes are the daemon's FundingHandler, mounted as serveSnapshot
// mounts it, behind a management token also made at start and kept in
// memory.
//
// Its companion, the wallet and prover zkapi-walletd (payCompanion), runs as
// serveSnapshot runs it: a child behind the daemon's authenticated CONNECT
// proxy, listening on 127.0.0.1:8790 and called with the bridge token made at
// start. All of them listen on the loopback of the payer's own network
// namespace, where the guest's boot starts cloak-pay, so nothing else in the
// guest, the agent's sandbox among them, can reach them. The configuration,
// the companion's state and the funding records are in the payer's home, the
// payment disk.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/signal"
	"path/filepath"
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
	payHeld     = 'H'
	payCall     = 'C'
	payView     = 'V'
	payAnswer   = 'A'
	// The largest frame either side takes, as the sender's; the daemon's API
	// takes request bodies up to the same size.
	payMaxFrame = 16 << 20
	// The companion as the guest image installs it, read-only. The daemon
	// finds the proving keys beside it, in
	// /opt/zkapi/share/zkapi-clientd/proof-setup.
	payCompanionBinary = "/opt/zkapi/bin/zkapi-walletd"
)

// payConfig is the daemon's default configuration with Tor as its only route,
// a new provider key for every request (Sean, 18 November), the guest's
// companion, and a management token of its own.
func payConfig() (config.Config, error) {
	c, err := config.Default()
	if err != nil {
		return config.Config{}, err
	}
	c.RelayURL = payTorRoute
	c.KeyReuseWindowSeconds = 0
	c.ZKAPI.Binary = payCompanionBinary
	if c.ManagementToken, err = config.Secret(); err != nil {
		return config.Config{}, err
	}
	return c, config.Validate(c)
}

// pay is the daemon's inference API, called in this process, with its key
// and management token, its wallet client, which reads the companion in this
// process, and its funding handler, which reads the chain.
type pay struct {
	api        http.Handler
	key        string
	token      string
	wallet     *zkapi.Client
	funding    *zkapi.FundingHandler
	logger     *log.Logger
	turns      payTurns
	background sync.WaitGroup // the daemon's session reporting and automatic settlement
}

// payInference is the daemon's zkInference with WaitSettled in front of each
// request: nothing asks for a key while the wallet reports a settlement
// unfinished. The request's context carries WaitSettled's held, under
// payHeldKey. The API answers a hold cancelled by the host or a stop as it
// answers any cancelled request (408), and a wallet error from the hold, or a
// held whose frame did not go, as an error it does not map (502).
type payInference struct{ zkInference }

// payHeldKey is the context key of a request's held: its H frames.
type payHeldKey struct{}

func (p payInference) Complete(ctx context.Context, body json.RawMessage) (*http.Response, error) {
	if err := p.Client.WaitSettled(ctx, ctx.Value(payHeldKey{}).(func(bool) error)); err != nil {
		return nil, err
	}
	return p.zkInference.Complete(ctx, body)
}

// newPay builds the API as the daemon's serveSnapshot does, from the same
// relay client, zkConfig, zkapi.Client, zkInference error mapping,
// FundingHandler with its records in dir, the configuration folder, server.API
// and request log, but with the hold in front of the backend and bearer
// authentication on, and runs the daemon's session reporting and automatic
// settlement for the life of ctx. The funding handler's public origin is the
// daemon's loopback address, which nothing listens on: the handler only
// checks that it is loopback.
func newPay(ctx context.Context, c config.Config, dir string, logger *log.Logger) (*pay, error) {
	client, err := relay.NewClient(c.RelayURL)
	if err != nil {
		return nil, err
	}
	wallet, err := zkapi.New(zkConfig(c, client))
	if err != nil {
		return nil, err
	}
	funding, err := zkapi.NewFundingHandler(wallet, "http://"+c.Listen, filepath.Join(dir, "funding"))
	if err != nil {
		return nil, err
	}
	api, err := server.New(payInference{zkInference{wallet}}, c.APIKey, c.Concurrency)
	if err != nil {
		return nil, err
	}
	api.RequireAPIKey = true
	api.ManagementToken = c.ManagementToken
	api.Admin = http.HandlerFunc(funding.ServeAdminHTTP)
	p := &pay{api: server.LogRequests(api, logger), key: c.APIKey, token: c.ManagementToken, wallet: wallet, funding: funding, logger: logger}
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

// payError is an answer of cloak-pay's own, in the daemon's admin error
// shape.
func payError(status int, message string) payAnswerFrame {
	data, _ := json.Marshal(map[string]string{"error": message})
	return payAnswerFrame{Status: status, Body: string(data)}
}

// payRoute is a route a C frame may call: a method and an exact path.
type payRoute struct{ method, path string }

// payRoutes are the money routes the Mac's payer calls, and the models, by
// exact method and path (docs/zkapi-mac-side.md, section 1): nothing else,
// no query and no other spelling, reaches the API.
var payRoutes = map[payRoute]bool{
	{http.MethodGet, "/admin/funding/address"}:     true,
	{http.MethodPost, "/admin/funding/quote"}:      true,
	{http.MethodPost, "/admin/funding/approve"}:    true,
	{http.MethodPost, "/admin/funding/deposit"}:    true,
	{http.MethodGet, "/admin/withdrawal"}:          true,
	{http.MethodPost, "/admin/withdrawal/quote"}:   true,
	{http.MethodPost, "/admin/withdrawal/approve"}: true,
	{http.MethodPost, "/admin/withdrawal"}:         true,
	{http.MethodGet, "/admin/return"}:              true,
	{http.MethodPost, "/admin/return/quote"}:       true,
	{http.MethodPost, "/admin/return/approve"}:     true,
	{http.MethodPost, "/admin/return"}:             true,
	{http.MethodGet, "/admin/funding/quote"}:       true,
	{http.MethodGet, "/admin/withdrawal/quote"}:    true,
	{http.MethodGet, "/admin/return/quote"}:        true,
	{http.MethodGet, "/v1/models"}:                 true,
}

// serve answers one connection's frame. A request that reads waits for its
// turn, then goes to the API; a call or a read goes at once. A connection
// whose first frame is none of these, or whose answer breaks off, gets no
// answer. If the host closes the connection first, what it asked is
// cancelled, as the daemon's HTTP server cancels a request whose client goes
// away: a request waiting for its turn leaves the queue, and one in the API
// ends before its key is asked for, if it has not been.
func (p *pay) serve(ctx context.Context, conn io.ReadWriter) error {
	kind, payload, err := readPayFrame(conn)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		_, _ = conn.Read(make([]byte, 1))
		cancel()
	}()
	var answer payAnswerFrame
	switch kind {
	case payRequest:
		answer, err = p.request(ctx, conn, payload)
	case payCall:
		answer, err = p.call(ctx, payload)
	case payView:
		answer, err = p.view(ctx, payload)
	default:
		return errors.New("the first frame is not a request, a call or a read")
	}
	if err != nil {
		return err
	}
	data, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return writePayFrame(conn, payAnswer, data)
}

// payDecode reads a frame's payload, which may hold only the keys v names.
func payDecode(payload []byte, v any) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	return decoder.Decode(v)
}

// request posts an R's body to the API's chat route in its turn, with the
// conversation's identity, and held, which writes the hold's H frames to
// the host, in its context.
func (p *pay) request(ctx context.Context, conn io.Writer, payload []byte) (payAnswerFrame, error) {
	var request struct {
		Identity string `json:"identity"`
		Body     string `json:"body"`
	}
	if payDecode(payload, &request) != nil || !payIdentity(request.Identity) {
		return payRefused, nil
	}
	end, err := p.turns.take(ctx)
	if err != nil {
		return payAnswerFrame{}, err
	}
	defer end()
	held := func(held bool) error {
		return writePayFrame(conn, payHeld, fmt.Appendf(nil, `{"held":%t}`, held))
	}
	ctx = context.WithValue(zkapi.WithConversation(ctx, request.Identity), payHeldKey{}, held)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "/v1/chat/completions", strings.NewReader(request.Body))
	if err != nil {
		return payAnswerFrame{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	return p.serveAPI(req)
}

// call sends a C to its route, with the management token, if payRoutes holds
// it; anything else is answered 404 without reaching the API.
func (p *pay) call(ctx context.Context, payload []byte) (payAnswerFrame, error) {
	var call struct {
		Method string `json:"method"`
		Path   string `json:"path"`
		Body   string `json:"body"`
	}
	if payDecode(payload, &call) != nil {
		return payError(http.StatusBadRequest, "the call does not read"), nil
	}
	if !payRoutes[payRoute{call.Method, call.Path}] {
		return payError(http.StatusNotFound, "unknown route"), nil
	}
	req, err := http.NewRequestWithContext(ctx, call.Method, call.Path, strings.NewReader(call.Body))
	if err != nil {
		return payAnswerFrame{}, err
	}
	req.Header.Set("X-OA-Management-Token", p.token)
	if call.Method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	return p.serveAPI(req)
}

// payWallet is the wallet's part of a V's answer: of the companion's
// /wallet/status, only whether there is a note, whether a settlement is
// unfinished, and the note's number and expiry.
type payWallet struct {
	HasNote        bool           `json:"has_note"`
	PendingRequest bool           `json:"pending_request"`
	Note           *payWalletNote `json:"note,omitempty"`
}

type payWalletNote struct {
	NoteID   uint32 `json:"note_id"`
	ExpiryTs uint64 `json:"expiry_ts"`
}

// payDeposit is a V's answer.
type payDeposit struct {
	Wallet payWallet        `json:"wallet"`
	Chain  *zkapi.ChainView `json:"chain,omitempty"`
}

// view answers a V with the wallet's status and, if asked, the chain at one
// block. A read that fails is answered 502, with no part of the deposit.
func (p *pay) view(ctx context.Context, payload []byte) (payAnswerFrame, error) {
	var view struct {
		Chain bool `json:"chain"`
	}
	if payDecode(payload, &view) != nil {
		return payError(http.StatusBadRequest, "the read does not read"), nil
	}
	deposit, err := p.deposit(ctx, view.Chain)
	if err != nil {
		return payError(http.StatusBadGateway, err.Error()), nil
	}
	data, err := json.Marshal(deposit)
	if err != nil {
		return payAnswerFrame{}, err
	}
	return payAnswerFrame{Status: http.StatusOK, Body: string(data)}, nil
}

func (p *pay) deposit(ctx context.Context, chain bool) (payDeposit, error) {
	status, err := p.wallet.WalletStatus(ctx)
	if err != nil {
		return payDeposit{}, err
	}
	var deposit payDeposit
	if err := json.Unmarshal(status, &deposit.Wallet); err != nil {
		return payDeposit{}, err
	}
	if chain {
		var note *uint32
		if deposit.Wallet.Note != nil {
			note = &deposit.Wallet.Note.NoteID
		}
		view, err := p.funding.ReadChain(ctx, note)
		if err != nil {
			return payDeposit{}, err
		}
		deposit.Chain = &view
	}
	return deposit, nil
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

// serveAPI calls the API in this process with its key and returns what it
// wrote.
func (p *pay) serveAPI(req *http.Request) (answer payAnswerFrame, err error) {
	req.Header.Set("Authorization", "Bearer "+p.key)
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
