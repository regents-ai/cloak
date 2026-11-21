//go:debug x509usefallbackroots=1

// Checks for cloak-pay without the guest. guest/pay/check.sh runs them in
// Linux, in the pinned Go image with no network, never on the Mac: the
// mainnet tree is untrusted. They build with guest/build.sh's overlay less
// zz_cloak_pay_linux.go, whose init would end the test binary, plus this
// file.
//
// Nothing here reaches a real service. A stand-in for the guest's Tor port
// notes, for each connection, the authentication methods offered, the user
// name and the destination. It refuses every destination but the two a paid
// request reaches through Tor, the model policy at the issuer and the
// inference at OpenRouter, and, in the checks that ask for it, the Ethereum
// RPC, a stand-in chain; it answers them itself over TLS, with a
// certificate from an authority made for the test. That authority is the
// only one this test binary trusts (the go:debug line above and
// x509.SetFallbackRoots), so the daemon's own transport is used unchanged.
// A stand-in companion on loopback answers the daemon's status, wallet,
// funding configuration, lease and settlement calls from a wallet and
// journal that outlive its process and cloak-pay's: each lease leaves its
// request pending until a settlement installs the result. Payment keys are
// made only in each check's own temporary folder.
package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"maps"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/config"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/zkapi"
)

const (
	standInModel  = "stand-in/model"
	standInAnswer = `{"id":"stand-in","object":"chat.completion","created":0,"model":"stand-in/model","choices":[{"index":0,"message":{"role":"assistant","content":"A canned answer."},"finish_reason":"stop"}]}`
)

// The pinned mainnet deployment, as the daemon embeds it.
type standInDeployment struct {
	ID       string `json:"deployment_id"`
	ChainID  uint64 `json:"chain_id"`
	Contract string `json:"contract_address"`
	Asset    string `json:"billing_asset"`
	Unit     string `json:"billing_unit"`
	Wei      string `json:"native_asset_wei_per_unit"`
	RPC      string `json:"rpc_url"`
	Proof    struct {
		Circuit string `json:"circuit_id"`
	} `json:"proof_setup"`
	Privacy struct {
		IssuerURL string `json:"issuer_url"`
	} `json:"privacy_mode"`
}

func pinnedMainnet(t *testing.T) standInDeployment {
	raw, err := os.ReadFile("../../internal/zkapi/deployments/mainnet.json")
	if err != nil {
		t.Fatal(err)
	}
	var d standInDeployment
	if err := json.Unmarshal(raw, &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func hostOf(t *testing.T, raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u.Hostname()
}

// One connection to the stand-in Tor port.
type torSeen struct {
	methods     []byte
	user        string
	destination string
}

type standInTor struct {
	listener net.Listener
	rpc      string // the Ethereum RPC's destination, host:port
	tls      chan net.Conn
	mu       sync.Mutex
	answered map[string]bool // destinations it serves, host:port
	chain    *standInChain   // the chain it serves at rpc, once asked
	seen     []torSeen
	keys     []string // the provider keys the inferences carried
	bodies   []string // the inference bodies as they arrived
}

// chanListener hands the stand-in's served connections to its HTTPS server,
// which closes it once.
type chanListener struct {
	conns  chan net.Conn
	closed chan struct{}
	addr   net.Addr
}

func (l chanListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}
func (l chanListener) Close() error   { close(l.closed); return nil }
func (l chanListener) Addr() net.Addr { return l.addr }

var (
	trustOnce sync.Once
	trustLeaf tls.Certificate
	trustErr  error
)

// standInCertificate makes the test authority and its certificate for the
// hosts, once for the binary, as x509.SetFallbackRoots may be called only
// once, and makes that authority the only one trusted.
func standInCertificate(t *testing.T, hosts ...string) tls.Certificate {
	trustOnce.Do(func() {
		var authority *x509.Certificate
		if authority, trustLeaf, trustErr = testCertificates(hosts...); trustErr == nil {
			pool := x509.NewCertPool()
			pool.AddCert(authority)
			x509.SetFallbackRoots(pool)
		}
	})
	if trustErr != nil {
		t.Fatal(trustErr)
	}
	return trustLeaf
}

// startTor starts the stand-in Tor port; it serves issuer and inference over
// TLS, as the destinations host:443, and rpc once serveChain asks.
func startTor(t *testing.T, issuer, inference, rpc string) *standInTor {
	leaf := standInCertificate(t, issuer, inference, rpc)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &standInTor{listener: listener, rpc: net.JoinHostPort(rpc, "443"), tls: make(chan net.Conn),
		answered: map[string]bool{net.JoinHostPort(issuer, "443"): true, net.JoinHostPort(inference, "443"): true}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET "+issuer+"/chat/model-tickets", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{%q: 1}`, standInModel)
	})
	mux.HandleFunc("GET "+issuer+"/chat/pinned-models", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"disabled_models": []}`)
	})
	mux.HandleFunc("POST "+inference+"/api/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.keys = append(s.keys, r.Header.Get("Authorization"))
		s.bodies = append(s.bodies, string(body))
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, standInAnswer)
	})
	mux.HandleFunc("POST "+rpc+"/", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		chain := s.chain
		s.mu.Unlock()
		chain.serve(w, r)
	})
	server := &http.Server{Handler: mux, ErrorLog: log.New(io.Discard, "", 0)}
	go func() {
		served := chanListener{s.tls, make(chan struct{}), listener.Addr()}
		_ = server.Serve(tls.NewListener(served, &tls.Config{Certificates: []tls.Certificate{leaf}}))
	}()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go s.handle(conn)
		}
	}()
	t.Cleanup(func() { listener.Close(); server.Close() })
	return s
}

// handle reads SOCKS5 (RFC 1928) with user name and password (RFC 1929), notes
// what it read, then serves or refuses the destination. A greeting that does
// not offer user name and password is noted and refused.
func (s *standInTor) handle(conn net.Conn) {
	var seen torSeen
	read := func(n int) []byte {
		b := make([]byte, n)
		if _, err := io.ReadFull(conn, b); err != nil {
			panic(err)
		}
		return b
	}
	defer func() {
		if recover() != nil {
			conn.Close()
		}
	}()
	head := read(2)
	seen.methods = read(int(head[1]))
	if !slices.Contains(seen.methods, 2) {
		s.note(seen)
		conn.Write([]byte{5, 0xff})
		conn.Close()
		return
	}
	conn.Write([]byte{5, 2})
	read(1)
	seen.user = string(read(int(read(1)[0])))
	read(int(read(1)[0]))
	conn.Write([]byte{1, 0})
	request := read(4)
	var host string
	switch request[3] {
	case 1:
		host = net.IP(read(4)).String()
	case 3:
		host = string(read(int(read(1)[0])))
	case 4:
		host = net.IP(read(16)).String()
	}
	seen.destination = net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(read(2)))))
	s.note(seen)
	s.mu.Lock()
	served := s.answered[seen.destination]
	s.mu.Unlock()
	if !served {
		conn.Write([]byte{5, 1, 0, 1, 0, 0, 0, 0, 0, 0})
		conn.Close()
		return
	}
	conn.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	s.tls <- conn
}

func (s *standInTor) note(seen torSeen) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seen = append(s.seen, seen)
}

func (s *standInTor) connections() []torSeen {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.seen)
}

// inferred gives the provider keys the inferences carried, in the order they
// arrived.
func (s *standInTor) inferred() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.keys)
}

// serveChain starts a stand-in chain and serves it as the Ethereum RPC.
func (s *standInTor) serveChain() *standInChain {
	chain := &standInChain{head: standInFirstBlock}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chain = chain
	s.answered[s.rpc] = true
	return chain
}

// The stand-in chain's first block, and the vault's selectors: paused()
// (OpenZeppelin's Pausable) and notes(uint32).
const (
	standInFirstBlock = 23_000_000
	standInPaused     = "0x5c975abb"
)

var standInNotes = "0x" + hex.EncodeToString(crypto.Keccak256([]byte("notes(uint32)"))[:4])

// standInChain is the Ethereum RPC. Its head moves on a block at every call,
// and every value it gives is chainAt's at the block it is read at, so values
// read at two blocks never agree with one block. It notes each call: the
// read, the block asked for ("latest", a number in hex, or none) and the
// address read.
type standInChain struct {
	mu    sync.Mutex
	head  uint64
	fail  string // the read it answers with an error
	calls []chainCall
}

type chainCall struct{ read, block, of string }

// chainAt is the chain at block: the block's time, the vault's pause, the
// funding address's balance and, with note, the vault's note 1.
func chainAt(block uint64, note bool) zkapi.ChainView {
	view := zkapi.ChainView{Block: block, Time: 1_794_000_000 + 12*(block-standInFirstBlock), Paused: block%2 == 1,
		BalanceWei: strconv.FormatUint(block*1_000_000_007, 10)}
	if note {
		view.Note = &zkapi.ChainNote{Status: []string{"uninitialized", "active", "pending_withdrawal", "closed"}[block%4], ExpiryTs: 1_795_000_000 + block}
	}
	return view
}

func standInWord(n uint64) string { return fmt.Sprintf("%064x", n) }

func (c *standInChain) serve(w http.ResponseWriter, r *http.Request) {
	var call struct {
		Method string            `json:"method"`
		Params []json.RawMessage `json:"params"`
	}
	if json.NewDecoder(r.Body).Decode(&call) != nil {
		http.Error(w, "{}", http.StatusBadRequest)
		return
	}
	param := func(i int) string {
		var value string
		if i < len(call.Params) {
			_ = json.Unmarshal(call.Params[i], &value)
		}
		return value
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	head := c.head
	c.head++
	seen := chainCall{read: call.Method}
	at := func(i int) uint64 {
		seen.block = param(i)
		if seen.block == "latest" {
			return head
		}
		block, _ := strconv.ParseUint(strings.TrimPrefix(seen.block, "0x"), 16, 64)
		return block
	}
	var result any
	switch call.Method {
	case "eth_chainId":
		result = "0x1"
	case "eth_getBlockByNumber":
		block := at(0)
		result = map[string]string{"number": "0x" + strconv.FormatUint(block, 16), "timestamp": "0x" + strconv.FormatUint(chainAt(block, false).Time, 16)}
	case "eth_getBalance":
		seen.of = param(0)
		balance, _ := new(big.Int).SetString(chainAt(at(1), false).BalanceWei, 10)
		result = "0x" + balance.Text(16)
	case "eth_call":
		var tx struct{ To, Data string }
		_ = json.Unmarshal(call.Params[0], &tx)
		seen.of = tx.To
		block := chainAt(at(1), true)
		switch tx.Data {
		case standInPaused:
			seen.read = "paused"
			result = "0x" + standInWord(block.Block%2)
		case standInNotes + standInWord(1):
			seen.read = "notes"
			status := slices.Index([]string{"uninitialized", "active", "pending_withdrawal", "closed"}, block.Note.Status)
			result = "0x" + strings.Repeat("ab", 32) + standInWord(1_000_000) + standInWord(block.Note.ExpiryTs) + standInWord(uint64(status))
		}
	}
	c.calls = append(c.calls, seen)
	w.Header().Set("Content-Type", "application/json")
	if result == nil || seen.read == c.fail {
		fmt.Fprint(w, `{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "stand-in"}}`)
		return
	}
	json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": result})
}

func (c *standInChain) failing(read string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.fail = read
}

func (c *standInChain) seen() []chainCall {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Clone(c.calls)
}

func testCertificates(hosts ...string) (*x509.Certificate, tls.Certificate, error) {
	authorityKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "cloak-pay test authority"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &authorityKey.PublicKey, authorityKey)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	authority, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	leafTemplate := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: hosts[0]}, DNSNames: hosts,
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, authority, &leafKey.PublicKey, authorityKey)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	return authority, tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: leafKey}, nil
}

// standInCompanion is the companion, with the wallet and journal it keeps,
// which outlive its process: each lease leaves its request pending until a
// settlement installs the result, and a settlement cut short leaves the
// journal as it was. It notes every call it gets.
type standInCompanion struct {
	*httptest.Server
	mu       sync.Mutex
	options  companionOptions
	pending  int         // the lease whose settlement is unfinished; 0 for none
	leases   int         // the leases handed out, numbered from 1
	attempts map[int]int // settlement calls that reached the wallet, by lease
	settled  map[int]int // settlements installed, by lease
	calls    []string
}

type companionOptions struct {
	// The companion has restarted with a request pending: its lease route
	// fails on that request (HTTP 502), as on the trip, where a running one
	// withholds the key (409 lease_pending).
	restarted bool
	// Each lease's first settlement outlasts the companion's own wait for the
	// server and answers 409 lease_pending; the next installs it.
	unfinished bool
	// When set, a settlement waits until gate closes and is cut if its caller
	// goes first; settling gets the lease of each one that waits.
	gate     chan struct{}
	settling chan int
	// The wallet has no note.
	noNote bool
}

type companionState struct {
	pending, leases   int
	attempts, settled map[int]int
	calls             []string
}

// startCompanion starts the stand-in companion: the status the daemon checks,
// the wallet's state, the funding configuration, a new lease for each
// request, and settlement.
func startCompanion(t *testing.T, bridge string, d standInDeployment) *standInCompanion {
	s := &standInCompanion{attempts: map[int]int{}, settled: map[int]int{}}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+bridge {
			http.Error(w, "{}", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch route := r.Method + " " + r.URL.Path; route {
		case "GET /oa/v1/status":
			s.note("status")
			json.NewEncoder(w).Encode(map[string]any{"chain_id": d.ChainID, "mode": "direct_openrouter", "require_oa_org_key_source": true,
				"bridge_version": 4, "deployment_id": d.ID, "contract_address": d.Contract, "billing_asset": d.Asset,
				"billing_unit": d.Unit, "circuit_id": d.Proof.Circuit})
		case "GET /wallet/status":
			s.mu.Lock()
			s.calls = append(s.calls, "wallet")
			pending, noNote := s.pending != 0, s.options.noNote
			s.mu.Unlock()
			if noNote {
				json.NewEncoder(w).Encode(map[string]any{"has_note": false, "pending_request": pending, "funding_url": "/funding"})
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"has_note": true, "pending_request": pending, "funding_url": "/funding",
				"note": map[string]any{"note_id": 1, "deposit_amount": 2000000, "current_balance": 1000000, "expiry_ts": 1795000000,
					"is_genesis": false, "current_anchor": "0x01", "current_commitment_x": "0x02", "current_commitment_y": "0x03"}})
		case "GET /funding/config":
			s.note("funding config")
			json.NewEncoder(w).Encode(map[string]any{"deployment_id": d.ID, "billing_asset": d.Asset, "billing_unit": d.Unit,
				"native_asset_wei_per_unit": d.Wei, "chain_id": d.ChainID, "contract_address": d.Contract,
				"demo_billing_token_address": "", "demo_rpc_url": d.RPC, "demo_mint_enabled": false})
		case "GET /oa/v1/withdraw/status":
			s.note("withdrawal")
			fmt.Fprint(w, `{"phase": "none"}`)
		case "POST /oa/v1/lease":
			s.lease(w)
		case "POST /wallet/settle":
			s.settle(w, r)
		case "GET /oa/v1/session-events":
			s.note("session-events")
			http.Error(w, "{}", http.StatusNotFound)
		default:
			s.note(route)
			http.Error(w, "{}", http.StatusNotFound)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *standInCompanion) note(call string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, call)
}

func (s *standInCompanion) configure(options companionOptions) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.options = options
}

// leftPending is the journal an earlier run left: lease's request pending,
// its settlement unfinished.
func (s *standInCompanion) leftPending(lease int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.leases, s.pending = lease, lease
}

func (s *standInCompanion) state() companionState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return companionState{s.pending, s.leases, maps.Clone(s.attempts), maps.Clone(s.settled), slices.Clone(s.calls)}
}

func (s *standInCompanion) lease(w http.ResponseWriter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.pending != 0 && s.options.restarted:
		s.calls = append(s.calls, "lease failed")
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprint(w, `{"error": {"code": "wallet_error"}}`)
	case s.pending != 0:
		s.calls = append(s.calls, "lease withheld")
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error": {"code": "lease_pending"}}`)
	default:
		s.leases++
		s.pending = s.leases
		s.calls = append(s.calls, fmt.Sprintf("lease %d", s.leases))
		json.NewEncoder(w).Encode(map[string]any{"api_key": fmt.Sprintf("stand-in-key-%d", s.leases), "base_url": zkapi.DefaultInferenceBaseURL,
			"expires_at": time.Now().Unix() + 300, "verified": true, "verification_status": "verified"})
	}
}

func (s *standInCompanion) settle(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	lease, gate, settling := s.pending, s.options.gate, s.options.settling
	s.mu.Unlock()
	if lease != 0 && gate != nil {
		settling <- lease
		select {
		case <-gate:
		case <-r.Context().Done():
			s.note(fmt.Sprintf("settle %d cut", lease))
			return
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	lease = s.pending
	if lease == 0 {
		s.calls = append(s.calls, "settle none")
		fmt.Fprint(w, `{"pending_request": false}`)
		return
	}
	s.attempts[lease]++
	if s.options.unfinished && s.attempts[lease] == 1 {
		s.calls = append(s.calls, fmt.Sprintf("settle %d unfinished", lease))
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error": {"code": "lease_pending"}}`)
		return
	}
	s.settled[lease]++
	s.pending = 0
	s.calls = append(s.calls, fmt.Sprintf("settle %d", lease))
	fmt.Fprint(w, `{"pending_request": false}`)
}

// paid keeps the calls that hand out a key or settle one: not a settlement
// call that found nothing pending.
func paid(calls []string) []string {
	var kept []string
	for _, call := range calls {
		if strings.HasPrefix(call, "lease") || (strings.HasPrefix(call, "settle") && call != "settle none") {
			kept = append(kept, call)
		}
	}
	return kept
}

// asked counts the calls of each kind made for requests: every call but the
// daemon's session reporter's. The reporter asks for the status, then the
// session events, at start and every five seconds, so each session-events
// call stands for one status call of its, noted before it. A round of its
// under way shows as one status call more, until its session-events call
// arrives; nothing else asks for the session events.
func (s companionState) asked() map[string]int {
	counts := map[string]int{}
	for _, call := range s.calls {
		counts[call]++
	}
	counts["status"] -= counts["session-events"]
	delete(counts, "session-events")
	if counts["status"] == 0 {
		delete(counts, "status")
	}
	return counts
}

// waitAsked waits, up to ten seconds, until the calls made for requests are
// exactly want.
func waitAsked(t *testing.T, companion *standInCompanion, want map[string]int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		s := companion.state()
		if got := s.asked(); maps.Equal(got, want) {
			return
		} else if time.Now().After(deadline) {
			t.Fatalf("asked for requests %v, want %v; calls %v", got, want, s.calls)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// standIns starts a stand-in Tor port and companion, and gives cloak-pay's
// configuration with them as its route and its companion.
func standIns(t *testing.T) (*standInTor, *standInCompanion, config.Config) {
	d := pinnedMainnet(t)
	tor := startTor(t, hostOf(t, d.Privacy.IssuerURL), hostOf(t, zkapi.DefaultInferenceBaseURL), hostOf(t, d.RPC))
	bridge := strings.Repeat("b", 64)
	companion := startCompanion(t, bridge, d)
	c, err := payConfig()
	if err != nil {
		t.Fatal(err)
	}
	c.RelayURL = "tor://" + tor.listener.Addr().String()
	c.ZKAPI.ClientURL = companion.URL
	c.ZKAPI.BridgeToken = bridge
	return tor, companion, c
}

func startPay(t *testing.T, ctx context.Context, c config.Config) *pay {
	return startPayIn(t, ctx, c, t.TempDir())
}

// startPayIn starts cloak-pay with dir as its home.
func startPayIn(t *testing.T, ctx context.Context, c config.Config, dir string) *pay {
	p, err := newPay(ctx, c, dir, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// sentFrame is a frame sent on a connection of its own, what cloak-pay
// writes back still to read. The pipe holds nothing: a frame cloak-pay
// writes waits until the host reads it.
type sentFrame struct {
	host   net.Conn
	served chan error // serve's result, when the test runs serve itself
}

// send sends one request frame to p over a pipe.
func send(t *testing.T, ctx context.Context, p *pay, request any) sentFrame {
	return sendFrame(t, ctx, p, payRequest, request)
}

// sendFrame sends one frame of kind to p over a pipe.
func sendFrame(t *testing.T, ctx context.Context, p *pay, kind byte, payload any) sentFrame {
	host, guest := net.Pipe()
	served := make(chan error, 1)
	go func() { served <- p.serve(ctx, guest); guest.Close() }()
	writeFrame(t, host, kind, payload)
	return sentFrame{host, served}
}

// writeFrame writes the frame, and returns once the guest has read it.
func writeFrame(t *testing.T, host net.Conn, kind byte, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := writePayFrame(host, kind, data); err != nil {
		t.Fatal(err)
	}
}

// next reads the next frame cloak-pay writes: for an H, what it holds; for
// the answer, done and the answer, once the connection is closed and serve
// has returned.
func (f sentFrame) next(t *testing.T) (held, done bool, answer payAnswerFrame) {
	t.Helper()
	kind, data, err := readPayFrame(f.host)
	switch {
	case err == nil && kind == payHeld && string(data) == `{"held":true}`:
		return true, false, answer
	case err == nil && kind == payHeld && string(data) == `{"held":false}`:
		return false, false, answer
	case err != nil || kind != payAnswer:
		t.Fatalf("frame %q %s %v", kind, data, err)
	}
	f.host.Close()
	if f.served != nil {
		if err := <-f.served; err != nil {
			t.Fatal(err)
		}
	}
	if err := json.Unmarshal(data, &answer); err != nil {
		t.Fatal(err)
	}
	return false, true, answer
}

// heard reads every frame cloak-pay writes, up to its answer, and gives the
// answer and the H frames before it.
func (f sentFrame) heard(t *testing.T) (payAnswerFrame, []bool) {
	t.Helper()
	var heard []bool
	for {
		held, done, answer := f.next(t)
		if done {
			return answer, heard
		}
		heard = append(heard, held)
	}
}

// answer reads the frames cloak-pay writes and gives its answer.
func (f sentFrame) answer(t *testing.T) payAnswerFrame {
	t.Helper()
	answer, _ := f.heard(t)
	return answer
}

// hangUp closes the connection before the answer, and waits for serve to
// end.
func (f sentFrame) hangUp(t *testing.T) {
	t.Helper()
	f.host.Close()
	select {
	case <-f.served:
	case <-time.After(10 * time.Second):
		t.Fatal("a request was still being served after its host hung up")
	}
}

// exchange sends one request frame to p over a pipe and reads its answer.
func exchange(t *testing.T, ctx context.Context, p *pay, request any) payAnswerFrame {
	t.Helper()
	return send(t, ctx, p, request).answer(t)
}

func ask(identity, text string) map[string]string {
	return map[string]string{"identity": identity, "body": chat(text)}
}

func identity(t *testing.T) string {
	identity, err := relay.NewTorIdentity()
	if err != nil {
		t.Fatal(err)
	}
	return identity
}

// pipeListener hands run the guest's ends of pipes, as the vsock port hands
// it connections from the host.
type pipeListener struct {
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), closed: make(chan struct{})}
}

func (l *pipeListener) Accept() (io.ReadWriteCloser, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

// send connects and sends one request frame.
func (l *pipeListener) send(t *testing.T, request any) sentFrame {
	host, guest := net.Pipe()
	l.conns <- guest
	writeFrame(t, host, payRequest, request)
	return sentFrame{host: host}
}

// callFrame sends a C to p and gives its answer, which no H comes before.
func callFrame(t *testing.T, ctx context.Context, p *pay, method, path, body string) payAnswerFrame {
	t.Helper()
	answer, held := sendFrame(t, ctx, p, payCall, map[string]string{"method": method, "path": path, "body": body}).heard(t)
	if len(held) != 0 {
		t.Fatalf("%s %s: H frames %v", method, path, held)
	}
	return answer
}

// viewFrame sends a V to p and gives its answer, which no H comes before.
func viewFrame(t *testing.T, ctx context.Context, p *pay, chain bool) payAnswerFrame {
	t.Helper()
	answer, held := sendFrame(t, ctx, p, payView, map[string]bool{"chain": chain}).heard(t)
	if len(held) != 0 {
		t.Fatalf("V: H frames %v", held)
	}
	return answer
}

// decoded is a JSON text as encoding/json reads it into an any, to compare
// keys and values whatever their order.
func decoded(t *testing.T, text string) any {
	t.Helper()
	var value any
	if err := json.Unmarshal([]byte(text), &value); err != nil {
		t.Fatalf("%v: %s", err, text)
	}
	return value
}

// waitFor waits, up to ten seconds, until done reports true.
func waitFor(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("still waiting for %s", what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// turnsTaken counts the requests holding or waiting for the turn.
func turnsTaken(p *pay) int {
	p.turns.mu.Lock()
	defer p.turns.mu.Unlock()
	return len(p.turns.queue)
}

// listening lists the listening TCP sockets of this network namespace: the
// test container's, which has loopback only and no other program listening.
func listening(t *testing.T) []string {
	var addresses []string
	for _, table := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		raw, err := os.ReadFile(table)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(raw), "\n")[1:] {
			// Local address and port in hex; state 0A is listening.
			if fields := strings.Fields(line); len(fields) > 3 && fields[3] == "0A" {
				addresses = append(addresses, procAddress(t, fields[1]))
			}
		}
	}
	sort.Strings(addresses)
	return addresses
}

// procAddress reads an address as /proc/net/tcp writes it: the IP in 32-bit
// words, each in the machine's byte order (little-endian on arm64), then
// the port.
func procAddress(t *testing.T, field string) string {
	hexIP, hexPort, _ := strings.Cut(field, ":")
	ip, err := hex.DecodeString(hexIP)
	port, portErr := strconv.ParseUint(hexPort, 16, 16)
	if err != nil || portErr != nil || len(ip)%4 != 0 {
		t.Fatalf("address %q", field)
	}
	for word := 0; word < len(ip); word += 4 {
		slices.Reverse(ip[word : word+4])
	}
	return net.JoinHostPort(net.IP(ip).String(), strconv.Itoa(int(port)))
}

func chat(text string) string {
	return fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"user":"dropped by the daemon"}`, standInModel, text)
}

// Two conversations' frames through the daemon's own path, from the
// companion's lease to the provider's answer, and what reached Tor.
func TestCloakPayFramesAndTorIdentities(t *testing.T) {
	d := pinnedMainnet(t)
	issuer, inference := hostOf(t, d.Privacy.IssuerURL), hostOf(t, zkapi.DefaultInferenceBaseURL)
	tor, companion, c := standIns(t)
	before := listening(t)
	stands := []string{tor.listener.Addr().String(), companion.Listener.Addr().String()}
	sort.Strings(stands)
	if !reflect.DeepEqual(before, stands) {
		t.Fatalf("before cloak-pay, listening %v, want the stand-ins %v", before, stands)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	a, b := identity(t), identity(t)
	sent := []string{chat("First conversation."), chat("Second conversation.")}
	for i, identity := range []string{a, b} {
		answer, heard := send(t, ctx, p, map[string]string{"identity": identity, "body": sent[i]}).heard(t)
		if answer.Status != http.StatusOK || answer.Body != standInAnswer {
			t.Fatalf("answer %d: %d %s", i, answer.Status, answer.Body)
		}
		// Nothing holds the first; the second is held only if the first's
		// settlement is not yet installed.
		if !(len(heard) == 0 || (i == 1 && slices.Equal(heard, []bool{true, false}))) {
			t.Fatalf("answer %d came after H frames %v", i, heard)
		}
	}

	// A frame without a conversation's identity is refused, and nothing
	// leaves for it.
	seenBefore, leasesBefore := len(tor.connections()), companion.state().leases
	for _, request := range []any{
		map[string]string{"identity": "not hex", "body": sent[0]},
		map[string]string{"identity": strings.ToUpper(a)[:62], "body": sent[0]},
		map[string]string{"body": sent[0]},
		map[string]string{"identity": a, "body": sent[0], "key": "a wallet key"},
	} {
		if answer := exchange(t, ctx, p, request); answer != payRefused {
			t.Fatalf("refused %v: %d %s", request, answer.Status, answer.Body)
		}
	}
	if len(tor.connections()) != seenBefore || companion.state().leases != leasesBefore {
		t.Fatal("a refused frame reached Tor or the companion")
	}

	if after := listening(t); !reflect.DeepEqual(after, before) {
		t.Fatalf("cloak-pay opened a listener: before %v, after %v", before, after)
	}

	// The companion's own connections go through the daemon's CONNECT
	// proxy; the stand-in refuses them.
	proxy, err := relay.StartConnectProxy(ctx, c.RelayURL)
	if err != nil {
		t.Fatal(err)
	}
	proxyURL, _ := url.Parse(proxy.URL)
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)}}
	for _, target := range []string{"https://zkapi-mainnet.openanonymity.ai/health", "https://ethereum-rpc.publicnode.com/"} {
		if _, err := client.Get(target); err == nil {
			t.Fatalf("%s answered through the stand-in", target)
		}
	}
	client.CloseIdleConnections()
	proxy.Close()

	// What reached Tor: everything under a user name and password, the two
	// inferences under their conversations' identities, every other
	// connection under one of its own.
	seen := tor.connections()
	var inferences, others []torSeen
	for _, s := range seen {
		if !bytes.Equal(s.methods, []byte{2}) {
			t.Fatalf("a connection offered %v", s.methods)
		}
		if s.destination == net.JoinHostPort(inference, "443") {
			inferences = append(inferences, s)
		} else {
			others = append(others, s)
		}
	}
	if len(inferences) != 2 || inferences[0].user != a || inferences[1].user != b {
		t.Fatalf("inferences %v, want under %s then %s", inferences, a, b)
	}
	users := map[string]bool{a: true, b: true}
	destinations := map[string]int{}
	for _, s := range others {
		if users[s.user] {
			t.Fatalf("%s reached Tor under an identity already used", s.destination)
		}
		users[s.user] = true
		destinations[s.destination]++
	}
	// Each request's model policy is two fetches from the issuer; the
	// companion's two connections went through the proxy.
	want := map[string]int{net.JoinHostPort(issuer, "443"): 4, "zkapi-mainnet.openanonymity.ai:443": 1, "ethereum-rpc.publicnode.com:443": 1}
	if !reflect.DeepEqual(destinations, want) {
		t.Fatalf("other connections %v, want %v", destinations, want)
	}

	// Two requests, two provider keys; each body as the Mac sent it, less
	// the fields the daemon never forwards.
	if keys := tor.inferred(); len(keys) != 2 || keys[0] == keys[1] {
		t.Fatalf("provider keys %v", keys)
	}
	tor.mu.Lock()
	bodies := slices.Clone(tor.bodies)
	tor.mu.Unlock()
	for i, body := range bodies {
		var got, want map[string]any
		_ = json.Unmarshal([]byte(body), &got)
		_ = json.Unmarshal([]byte(sent[i]), &want)
		delete(want, "user")
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("inference body %d: %s", i, body)
		}
	}
}

func TestCloakPayAcceptsTheHostOnly(t *testing.T) {
	// The hypervisor, the guest's own loopback, the host, a guest (the Mac
	// gives its guest 3), and VMADDR_CID_ANY.
	for cid, want := range map[uint32]bool{0: false, 1: false, 2: true, 3: false, 0xFFFFFFFF: false} {
		if payFromHost(cid) != want {
			t.Errorf("CID %d: accepted %t", cid, !want)
		}
	}
}

func TestCloakPayStartsOnlyOnTor(t *testing.T) {
	c, err := payConfig()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for _, route := range []string{"", "socks5://127.0.0.1:9050", "wss://relay.example/", "tor://203.0.113.1:9050", "tor://user@127.0.0.1:9050"} {
		c.RelayURL = route
		if _, err := newPay(ctx, c, t.TempDir(), log.New(io.Discard, "", 0)); err == nil {
			t.Errorf("started on %q", route)
		}
		if proxy, err := relay.StartConnectProxy(ctx, route); err == nil {
			proxy.Close()
			t.Errorf("proxy started on %q", route)
		}
	}
}

// settlingLease waits, up to ten seconds, for a settlement to wait at the
// stand-in companion's gate, and gives its lease.
func settlingLease(t *testing.T, settling chan int) int {
	t.Helper()
	select {
	case lease := <-settling:
		return lease
	case <-time.After(10 * time.Second):
		t.Fatal("no settlement started")
		return 0
	}
}

func begins(calls, want []string) bool {
	return len(calls) >= len(want) && slices.Equal(calls[:len(want)], want)
}

// Two frames sent together: the second is held until the first's settlement
// is installed, here once automatic settlement's call has outlasted the
// companion's wait, and both are answered. Either may take the first turn;
// the host hears the hold of the one that takes the second begin and end,
// once each, and nothing for the other, which nothing held.
func TestCloakPayHoldsTheNextRequest(t *testing.T) {
	tor, companion, c := standIns(t)
	companion.configure(companionOptions{unfinished: true})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	p := startPay(t, ctx, c)
	first := send(t, ctx, p, ask(identity(t), "First, sent with the second."))
	second := send(t, ctx, p, ask(identity(t), "Second, sent with the first."))
	var heard [][]bool
	for i, frame := range []sentFrame{first, second} {
		answer, held := frame.heard(t)
		if answer.Status != http.StatusOK || answer.Body != standInAnswer {
			t.Fatalf("answer %d: %d %s", i+1, answer.Status, answer.Body)
		}
		heard = append(heard, held)
	}
	slices.SortFunc(heard, func(a, b []bool) int { return len(a) - len(b) })
	if len(heard[0]) != 0 || !slices.Equal(heard[1], []bool{true, false}) {
		t.Fatalf("H frames %v, want none for one request and true then false for the other", heard)
	}
	want := []string{"lease 1", "settle 1 unfinished", "settle 1", "lease 2"}
	if calls := paid(companion.state().calls); !begins(calls, want) {
		t.Fatalf("paid calls %v, want first %v", calls, want)
	}
	if keys := tor.inferred(); !slices.Equal(keys, []string{"Bearer stand-in-key-1", "Bearer stand-in-key-2"}) {
		t.Fatalf("inferences under %v", keys)
	}
}

// A settlement an earlier run left unfinished: the first request is held,
// with no key asked for and nothing sent, until the companion installs that
// settlement, then answered. Asked for a key first, the restarted companion
// would fail, as on the trip. The host hears the hold begin before the
// settlement, and its end once the settlement is installed, before any key
// is asked for: the pipe holds nothing, so until the host reads that end,
// cloak-pay can go no further.
func TestCloakPayHoldsForAnEarlierRun(t *testing.T) {
	tor, companion, c := standIns(t)
	companion.leftPending(7)
	gate, settling := make(chan struct{}), make(chan int, 4)
	companion.configure(companionOptions{restarted: true, gate: gate, settling: settling})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	first := send(t, ctx, p, ask(identity(t), "First after a restart."))
	if began, done, answer := first.next(t); done || !began {
		t.Fatalf("first frame: held %t, answer %d %s", began, answer.Status, answer.Body)
	}
	if lease := settlingLease(t, settling); lease != 7 {
		t.Fatalf("settling lease %d", lease)
	}
	if s := companion.state(); s.leases != 7 || len(tor.connections()) != 0 {
		t.Fatalf("while held, %d leases and %d connections to Tor", s.leases, len(tor.connections()))
	}
	close(gate)
	waitFor(t, "the settlement to be installed", func() bool { return companion.state().settled[7] == 1 })
	// Given time to ask for a key before the host has heard the hold end, it
	// asks for none.
	time.Sleep(100 * time.Millisecond)
	if s := companion.state(); s.leases != 7 || len(tor.connections()) != 0 {
		t.Fatalf("before the host heard the hold end, %d leases and %d connections to Tor", s.leases, len(tor.connections()))
	}
	if answer, heard := first.heard(t); answer.Status != http.StatusOK || answer.Body != standInAnswer || !slices.Equal(heard, []bool{false}) {
		t.Fatalf("answer: %d %s, after H frames %v", answer.Status, answer.Body, heard)
	}
	s := companion.state()
	if want := []string{"settle 7", "lease 8"}; !begins(paid(s.calls), want) || s.settled[7] != 1 {
		t.Fatalf("paid calls %v, want first %v", paid(s.calls), want)
	}
	if keys := tor.inferred(); !slices.Equal(keys, []string{"Bearer stand-in-key-8"}) {
		t.Fatalf("inferences under %v", keys)
	}
}

// SIGTERM while automatic settlement is under way, the next request held
// behind it: the held request is answered as cancelled, the settlement is cut
// and left in the journal, and run returns. The next run settles that
// request once, before it asks for a key, and answers.
func TestCloakPayStopsOnSIGTERM(t *testing.T) {
	tor, companion, c := standIns(t)
	gate, settling := make(chan struct{}), make(chan int, 4)
	companion.configure(companionOptions{gate: gate, settling: settling})
	life, stop := payLife()
	defer stop()
	p := startPay(t, life, c)
	listener := newPipeListener()
	ran := make(chan error, 1)
	go func() { ran <- p.run(life, listener) }()

	if answer := listener.send(t, ask(identity(t), "Before the stop.")).answer(t); answer.Status != http.StatusOK {
		t.Fatalf("answer: %d %s", answer.Status, answer.Body)
	}
	if lease := settlingLease(t, settling); lease != 1 {
		t.Fatalf("settling lease %d", lease)
	}
	held := listener.send(t, ask(identity(t), "Held at the stop."))
	waitFor(t, "the held request to take its turn", func() bool { return turnsTaken(p) == 1 })
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	// Its hold, if it began, never ends: no key is asked for.
	if answer, heard := held.heard(t); answer.Status != http.StatusRequestTimeout || slices.Contains(heard, false) {
		t.Fatalf("held request: %d %s, after H frames %v", answer.Status, answer.Body, heard)
	}
	select {
	case err := <-ran:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("cloak-pay did not stop")
	}
	waitFor(t, "the settlement to be cut", func() bool { return slices.Contains(companion.state().calls, "settle 1 cut") })
	if s := companion.state(); s.pending != 1 || s.leases != 1 || s.attempts[1] != 0 {
		t.Fatalf("after the stop, lease %d pending, %d leases, %d settlement calls", s.pending, s.leases, s.attempts[1])
	}

	companion.configure(companionOptions{restarted: true})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	next := startPay(t, ctx, c)
	if answer := exchange(t, ctx, next, ask(identity(t), "After the stop.")); answer.Status != http.StatusOK || answer.Body != standInAnswer {
		t.Fatalf("next run's answer: %d %s", answer.Status, answer.Body)
	}
	s := companion.state()
	if want := []string{"lease 1", "settle 1 cut", "settle 1", "lease 2"}; !begins(paid(s.calls), want) || s.attempts[1] != 1 || s.settled[1] != 1 {
		t.Fatalf("paid calls %v, want first %v", paid(s.calls), want)
	}
	if keys := tor.inferred(); !slices.Equal(keys, []string{"Bearer stand-in-key-1", "Bearer stand-in-key-2"}) {
		t.Fatalf("inferences under %v", keys)
	}
}

// Requests whose hosts hang up while they are held end at once: nothing
// reaches Tor or the companion for them, no key is asked for, and the next
// request is served. Every call a request makes is answered before its serve
// returns, but for one a hang-up cuts, so once hangUp has returned and the
// cut call has arrived, what was asked for it is final.
func TestCloakPayDropsAHeldRequest(t *testing.T) {
	t.Run("behind automatic settlement, and waiting for its turn", func(t *testing.T) {
		tor, companion, c := standIns(t)
		gate, settling := make(chan struct{}), make(chan int, 4)
		companion.configure(companionOptions{gate: gate, settling: settling})
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		p := startPay(t, ctx, c)
		if answer := exchange(t, ctx, p, ask(identity(t), "Answered.")); answer.Status != http.StatusOK {
			t.Fatalf("answer: %d %s", answer.Status, answer.Body)
		}
		if lease := settlingLease(t, settling); lease != 1 {
			t.Fatalf("settling lease %d", lease)
		}
		// The answered request's: the hold's reading of the wallet (status,
		// wallet, withdrawal), then the daemon's check and key (status, lease).
		answered := map[string]int{"status": 2, "wallet": 1, "withdrawal": 1, "lease 1": 1}
		waitAsked(t, companion, answered)
		held := send(t, ctx, p, ask(identity(t), "Held."))
		waitFor(t, "the held request to take its turn", func() bool { return turnsTaken(p) == 1 })
		waiting := send(t, ctx, p, ask(identity(t), "Waiting for its turn."))
		waitFor(t, "the next request to wait for its turn", func() bool { return turnsTaken(p) == 2 })
		seen := len(tor.connections())
		held.hangUp(t)
		waiting.hangUp(t)
		close(gate)
		// Its settlement, and nothing for the two whose hosts hung up.
		answered["settle 1"] = 1
		waitAsked(t, companion, answered)
		if len(tor.connections()) != seen || turnsTaken(p) != 0 {
			t.Fatalf("after the hang-ups, %d connections to Tor (was %d), %d turns taken", len(tor.connections()), seen, turnsTaken(p))
		}
		if answer := exchange(t, ctx, p, ask(identity(t), "Sent after.")); answer.Status != http.StatusOK {
			t.Fatalf("next answer: %d %s", answer.Status, answer.Body)
		}
		if keys := tor.inferred(); !slices.Equal(keys, []string{"Bearer stand-in-key-1", "Bearer stand-in-key-2"}) {
			t.Fatalf("inferences under %v", keys)
		}
	})
	t.Run("in the settlement of a request an earlier run left", func(t *testing.T) {
		tor, companion, c := standIns(t)
		companion.leftPending(7)
		gate, settling := make(chan struct{}), make(chan int, 4)
		companion.configure(companionOptions{restarted: true, gate: gate, settling: settling})
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		p := startPay(t, ctx, c)
		held := send(t, ctx, p, ask(identity(t), "Held."))
		if began, done, answer := held.next(t); done || !began {
			t.Fatalf("first frame: held %t, answer %d %s", began, answer.Status, answer.Body)
		}
		if lease := settlingLease(t, settling); lease != 7 {
			t.Fatalf("settling lease %d", lease)
		}
		held.hangUp(t)
		// The hold's reading of the wallet and its settlement call, which the
		// hang-up cut, and nothing after.
		waitAsked(t, companion, map[string]int{"status": 1, "wallet": 1, "withdrawal": 1, "settle 7 cut": 1})
		if len(tor.connections()) != 0 {
			t.Fatalf("after the hang-up, %d connections to Tor", len(tor.connections()))
		}
		close(gate)
		if answer := exchange(t, ctx, p, ask(identity(t), "Sent after.")); answer.Status != http.StatusOK {
			t.Fatalf("next answer: %d %s", answer.Status, answer.Body)
		}
		if s := companion.state(); s.settled[7] != 1 || !slices.Equal(tor.inferred(), []string{"Bearer stand-in-key-8"}) {
			t.Fatalf("settlements of the earlier request %d, inferences under %v", s.settled[7], tor.inferred())
		}
	})
}

// The C frame's routes, as docs/zkapi-mac-side.md lists them.
var macRoutes = []payRoute{
	{"GET", "/admin/funding/address"},
	{"POST", "/admin/funding/quote"},
	{"POST", "/admin/funding/approve"},
	{"POST", "/admin/funding/deposit"},
	{"GET", "/admin/withdrawal"},
	{"POST", "/admin/withdrawal/quote"},
	{"POST", "/admin/withdrawal/approve"},
	{"POST", "/admin/withdrawal"},
	{"GET", "/admin/return"},
	{"POST", "/admin/return/quote"},
	{"POST", "/admin/return/approve"},
	{"POST", "/admin/return"},
	{"GET", "/admin/funding/quote"},
	{"GET", "/admin/withdrawal/quote"},
	{"GET", "/admin/return/quote"},
	{"GET", "/v1/models"},
}

// A C reaches the API for each of the Mac's routes, exactly as sent, with
// the key and management token cloak-pay adds and a POST as JSON. Anything
// else, a frame that does not read among it, is answered without reaching
// the API: another method, a query, a path one character off, and the
// paying chat route among them.
func TestCloakPayCallsTheAllowlistOnly(t *testing.T) {
	_, _, c := standIns(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	type reached struct{ method, uri, key, token, contentType, body string }
	var mu sync.Mutex
	var got []reached
	p.api = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, reached{r.Method, r.URL.RequestURI(), r.Header.Get("Authorization"), r.Header.Get("X-OA-Management-Token"), r.Header.Get("Content-Type"), string(body)})
		mu.Unlock()
		fmt.Fprint(w, `{"reached": true}`)
	})
	taken := func() []reached {
		mu.Lock()
		defer mu.Unlock()
		taken := got
		got = nil
		return taken
	}
	allowed := map[payRoute]bool{}
	for _, route := range macRoutes {
		allowed[route] = true
		body, contentType := "", ""
		if route.method == http.MethodPost {
			body, contentType = `{"quote_id": "q"}`, "application/json"
		}
		answer := callFrame(t, ctx, p, route.method, route.path, body)
		want := []reached{{route.method, route.path, "Bearer " + c.APIKey, c.ManagementToken, contentType, body}}
		if reached := taken(); answer.Status != http.StatusOK || answer.Body != `{"reached": true}` || !slices.Equal(reached, want) {
			t.Fatalf("%s %s: %d %s, reached %v", route.method, route.path, answer.Status, answer.Body, reached)
		}
	}
	if len(payRoutes) != len(allowed) {
		t.Fatalf("cloak-pay allows %d routes, the Mac calls %d", len(payRoutes), len(allowed))
	}

	var refused []payRoute
	refuse := func(method, path string) {
		if !allowed[payRoute{method, path}] {
			refused = append(refused, payRoute{method, path})
		}
	}
	for _, route := range macRoutes {
		refuse(map[string]string{"GET": "POST", "POST": "GET"}[route.method], route.path)
		refuse(strings.ToLower(route.method), route.path)
		refuse(http.MethodPut, route.path)
		refuse(route.method, route.path+"?a=1")
		refuse(route.method, route.path+"/")
		refuse(route.method, route.path+"x")
		refuse(route.method, route.path[:len(route.path)-1])
		refuse(route.method, strings.ToUpper(route.path))
		refuse(route.method, " "+route.path)
		refuse(route.method, "/"+route.path)
	}
	refuse(http.MethodPost, "/v1/chat/completions")
	refuse(http.MethodGet, "/admin/status")
	refuse(http.MethodGet, "/admin/withdrawal/../return")
	refuse(http.MethodGet, "http://127.0.0.1:8787/admin/withdrawal")
	refuse(http.MethodGet, "")
	refuse("", "")
	if !slices.Contains(refused, payRoute{http.MethodGet, "/admin/funding/approve"}) {
		t.Fatal("GET /admin/funding/approve is not among the refused")
	}
	for _, route := range refused {
		if answer := callFrame(t, ctx, p, route.method, route.path, ""); answer.Status != http.StatusNotFound {
			t.Fatalf("%q %q: %d %s", route.method, route.path, answer.Status, answer.Body)
		}
	}
	for _, frame := range []any{
		map[string]string{"method": "GET", "path": "/admin/withdrawal", "body": "", "token": "the host's"},
		map[string]any{"method": "GET", "path": 1, "body": ""},
		[]string{"GET", "/admin/withdrawal"},
		"GET /admin/withdrawal",
	} {
		if answer, heard := sendFrame(t, ctx, p, payCall, frame).heard(t); answer.Status != http.StatusBadRequest || len(heard) != 0 {
			t.Fatalf("%v: %d %s, after H frames %v", frame, answer.Status, answer.Body, heard)
		}
	}
	if reached := taken(); len(reached) != 0 {
		t.Fatalf("refused calls reached the API: %v", reached)
	}
}

// fundingKey reads the funding address and its key from cloak-pay's home,
// where its first read of the address made them.
func fundingKey(t *testing.T, dir string) (address, key string) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "funding", "mainnet", "address-funding.json"))
	if err != nil {
		t.Fatal(err)
	}
	var record struct {
		Address    string `json:"address"`
		PrivateKey string `json:"private_key"`
	}
	if err := json.Unmarshal(raw, &record); err != nil {
		t.Fatal(err)
	}
	return record.Address, record.PrivateKey
}

// Every one of the Mac's routes, called through the daemon's own handlers
// against the stand-in chain, reaches a route the daemon knows, and no
// answer carries the API's key, the management token, the companion's bridge
// token or the funding address's key. With no quote approved, none of them
// sends a transaction.
func TestCloakPayCallsKeepTheSecrets(t *testing.T) {
	tor, _, c := standIns(t)
	chain := tor.serveChain()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dir := t.TempDir()
	p := startPayIn(t, ctx, c, dir)
	destination := "0x" + strings.Repeat("11", 20)
	bodies := map[payRoute]string{
		{"POST", "/admin/funding/quote"}:      `{"micro_usd": 1000000}`,
		{"POST", "/admin/funding/approve"}:    `{"quote_id": "not a quote"}`,
		{"POST", "/admin/funding/deposit"}:    `{"amount": 1}`,
		{"POST", "/admin/withdrawal/quote"}:   fmt.Sprintf(`{"destination": %q, "note_id": 1}`, destination),
		{"POST", "/admin/withdrawal/approve"}: `{"quote_id": "not a quote"}`,
		{"POST", "/admin/withdrawal"}:         fmt.Sprintf(`{"destination": %q, "note_id": 1}`, destination),
		{"POST", "/admin/return/quote"}:       fmt.Sprintf(`{"destination": %q, "amount_wei": ""}`, destination),
		{"POST", "/admin/return/approve"}:     `{"quote_id": "not a quote"}`,
	}
	var answers []string
	for _, route := range macRoutes {
		answer := callFrame(t, ctx, p, route.method, route.path, bodies[route])
		if answer.Status == http.StatusNotFound {
			t.Fatalf("%s %s: the daemon has no such route: %s", route.method, route.path, answer.Body)
		}
		answers = append(answers, fmt.Sprintf("%s %s: %d %s", route.method, route.path, answer.Status, answer.Body))
	}
	_, key := fundingKey(t, dir)
	secrets := []string{c.APIKey, c.ManagementToken, c.ZKAPI.BridgeToken, strings.TrimPrefix(key, "0x")}
	for _, secret := range secrets {
		if len(secret) < 32 {
			t.Fatalf("a secret of %d characters", len(secret))
		}
	}
	for _, answer := range answers {
		for _, secret := range secrets {
			if strings.Contains(strings.ToLower(answer), strings.ToLower(secret)) {
				t.Fatalf("an answer carries a secret: %s", answer)
			}
		}
	}
	for _, call := range chain.seen() {
		if strings.HasPrefix(call.read, "eth_send") {
			t.Fatalf("a call sent a transaction: %v", call)
		}
	}
}

// A V's answer holds exactly the contract's keys: of the companion's wallet
// status only the note's number and expiry and whether a settlement is
// unfinished, and with "chain" the chain at one block, none without; with
// no note, neither part has one. A V without "chain" reads no chain, and a
// frame that does not read is answered 400.
func TestCloakPayViewsTheDeposit(t *testing.T) {
	tor, companion, c := standIns(t)
	chain := tor.serveChain()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	wallet := `{"has_note": true, "pending_request": false, "note": {"note_id": 1, "expiry_ts": 1795000000}}`
	if answer := viewFrame(t, ctx, p, false); answer.Status != http.StatusOK || !reflect.DeepEqual(decoded(t, answer.Body), decoded(t, `{"wallet": `+wallet+`}`)) {
		t.Fatalf("without chain: %d %s", answer.Status, answer.Body)
	}
	if calls := chain.seen(); len(calls) != 0 {
		t.Fatalf("a V without chain read the chain: %v", calls)
	}
	block := func(body string) uint64 {
		var read struct{ Chain struct{ Block uint64 } }
		_ = json.Unmarshal([]byte(body), &read)
		return read.Chain.Block
	}

	answer := viewFrame(t, ctx, p, true)
	at := chainAt(block(answer.Body), true)
	want := fmt.Sprintf(`{"wallet": %s, "chain": {"block": %d, "time": %d, "paused": %t, "balance_wei": %q, "note": {"status": %q, "expiry_ts": %d}}}`,
		wallet, at.Block, at.Time, at.Paused, at.BalanceWei, at.Note.Status, at.Note.ExpiryTs)
	if answer.Status != http.StatusOK || !reflect.DeepEqual(decoded(t, answer.Body), decoded(t, want)) {
		t.Fatalf("with chain: %d %s, want %s", answer.Status, answer.Body, want)
	}

	companion.configure(companionOptions{noNote: true})
	read := len(chain.seen())
	answer = viewFrame(t, ctx, p, true)
	at = chainAt(block(answer.Body), false)
	want = fmt.Sprintf(`{"wallet": {"has_note": false, "pending_request": false}, "chain": {"block": %d, "time": %d, "paused": %t, "balance_wei": %q}}`,
		at.Block, at.Time, at.Paused, at.BalanceWei)
	if answer.Status != http.StatusOK || !reflect.DeepEqual(decoded(t, answer.Body), decoded(t, want)) {
		t.Fatalf("without a note: %d %s, want %s", answer.Status, answer.Body, want)
	}
	for _, call := range chain.seen()[read:] {
		if call.read == "notes" {
			t.Fatal("a V without a note read the vault's notes")
		}
	}

	for _, frame := range []any{map[string]any{"chain": true, "note": 1}, map[string]any{"chain": "yes"}, []bool{true}} {
		if answer, heard := sendFrame(t, ctx, p, payView, frame).heard(t); answer.Status != http.StatusBadRequest || len(heard) != 0 {
			t.Fatalf("%v: %d %s, after H frames %v", frame, answer.Status, answer.Body, heard)
		}
	}
}

// The chain read is pinned to the block "latest" gave: every read after it
// asks for that block by number, of the vault or the funding address, and
// the values all belong to that block, though the head moves on a block at
// every call.
func TestCloakPayReadsTheChainAtOneBlock(t *testing.T) {
	tor, _, c := standIns(t)
	chain := tor.serveChain()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dir := t.TempDir()
	p := startPayIn(t, ctx, c, dir)
	answer := viewFrame(t, ctx, p, true)
	var view struct{ Chain zkapi.ChainView }
	if err := json.Unmarshal([]byte(answer.Body), &view); err != nil || answer.Status != http.StatusOK {
		t.Fatalf("%d %s", answer.Status, answer.Body)
	}
	if want := chainAt(view.Chain.Block, true); !reflect.DeepEqual(view.Chain, want) {
		t.Fatalf("read %+v %+v, want the block's %+v %+v", view.Chain, view.Chain.Note, want, want.Note)
	}
	address, _ := fundingKey(t, dir)
	vault := strings.ToLower(pinnedMainnet(t).Contract)
	block := "0x" + strconv.FormatUint(view.Chain.Block, 16)
	want := []chainCall{{"eth_chainId", "", ""}, {"eth_getBlockByNumber", "latest", ""},
		{"paused", block, vault}, {"eth_getBalance", block, strings.ToLower(address)}, {"notes", block, vault}}
	calls := chain.seen()
	for i := range calls {
		calls[i].of = strings.ToLower(calls[i].of)
	}
	if !slices.Equal(calls, want) {
		t.Fatalf("reads %v, want %v", calls, want)
	}
	chain.mu.Lock()
	head := chain.head
	chain.mu.Unlock()
	if head != view.Chain.Block+uint64(len(want))-1 {
		t.Fatalf("head %d after reading block %d", head, view.Chain.Block)
	}
}

// When any one of the chain's reads fails, a V with "chain" answers 502 with
// nothing of the deposit: no wallet part, no chain part, never a guess.
func TestCloakPayFailsAChainReadWhole(t *testing.T) {
	tor, _, c := standIns(t)
	chain := tor.serveChain()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	for _, read := range []string{"eth_chainId", "eth_getBlockByNumber", "paused", "eth_getBalance", "notes"} {
		chain.failing(read)
		answer := viewFrame(t, ctx, p, true)
		var body map[string]any
		if err := json.Unmarshal([]byte(answer.Body), &body); err != nil || answer.Status != http.StatusBadGateway || len(body) != 1 || body["error"] == nil {
			t.Fatalf("%s failing: %d %s", read, answer.Status, answer.Body)
		}
	}
	chain.failing("")
	if answer := viewFrame(t, ctx, p, true); answer.Status != http.StatusOK {
		t.Fatalf("nothing failing: %d %s", answer.Status, answer.Body)
	}
}

// While a request is held, a C and two Vs are answered, each within ten
// seconds: none waits for a turn, and the Vs read the settlement still
// unfinished. Then the request is answered.
func TestCloakPayAnswersCallsWhileHeld(t *testing.T) {
	tor, companion, c := standIns(t)
	tor.serveChain()
	companion.leftPending(7)
	gate, settling := make(chan struct{}), make(chan int, 4)
	companion.configure(companionOptions{restarted: true, gate: gate, settling: settling})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	held := send(t, ctx, p, ask(identity(t), "Held."))
	if began, done, answer := held.next(t); done || !began {
		t.Fatalf("first frame: held %t, answer %d %s", began, answer.Status, answer.Body)
	}
	if lease := settlingLease(t, settling); lease != 7 {
		t.Fatalf("settling lease %d", lease)
	}
	// A call that waited past this would be closed unanswered.
	calls, stop := context.WithTimeout(ctx, 10*time.Second)
	defer stop()
	wallet := `{"has_note": true, "pending_request": true, "note": {"note_id": 1, "expiry_ts": 1795000000}}`
	if answer := viewFrame(t, calls, p, false); answer.Status != http.StatusOK || !reflect.DeepEqual(decoded(t, answer.Body), decoded(t, `{"wallet": `+wallet+`}`)) {
		t.Fatalf("V: %d %s", answer.Status, answer.Body)
	}
	if answer := viewFrame(t, calls, p, true); answer.Status != http.StatusOK {
		t.Fatalf("V with chain: %d %s", answer.Status, answer.Body)
	}
	if answer := callFrame(t, calls, p, "GET", "/admin/funding/quote", ""); answer.Status != http.StatusOK || decoded(t, answer.Body) != nil {
		t.Fatalf("C: %d %s", answer.Status, answer.Body)
	}
	if s := companion.state(); s.leases != 7 || turnsTaken(p) != 1 {
		t.Fatalf("while held, %d leases and %d turns taken", s.leases, turnsTaken(p))
	}
	close(gate)
	if answer, heard := held.heard(t); answer.Status != http.StatusOK || !slices.Equal(heard, []bool{false}) {
		t.Fatalf("answer: %d %s, after H frames %v", answer.Status, answer.Body, heard)
	}
}

// Turns go in the order asked for; one whose caller goes while it waits
// leaves the queue without holding up the next.
func TestCloakPayTurnsInOrder(t *testing.T) {
	var turns payTurns
	queued := func() int {
		turns.mu.Lock()
		defer turns.mu.Unlock()
		return len(turns.queue)
	}
	end, err := turns.take(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	served := make(chan string, 3)
	goes, leave := context.WithCancel(context.Background())
	defer leave()
	for i, name := range []string{"B", "C", "D"} {
		ctx := context.Background()
		if name == "B" {
			ctx = goes
		}
		go func() {
			end, err := turns.take(ctx)
			if err != nil {
				served <- name + " left"
				return
			}
			served <- name
			end()
		}()
		waitFor(t, name+" to wait for its turn", func() bool { return queued() == i+2 })
	}
	next := func() string {
		select {
		case name := <-served:
			return name
		case <-time.After(10 * time.Second):
			return "nobody"
		}
	}
	leave()
	if got := next(); got != "B left" {
		t.Fatalf("first %s, want B left", got)
	}
	end()
	for _, want := range []string{"C", "D"} {
		if got := next(); got != want {
			t.Fatalf("served %s, want %s", got, want)
		}
	}
	waitFor(t, "the queue to empty", func() bool { return queued() == 0 })
}
