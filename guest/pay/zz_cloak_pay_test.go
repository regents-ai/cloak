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
// inference at OpenRouter, which it answers itself over TLS, with a
// certificate from an authority made for the test. That authority is the
// only one this test binary trusts (the go:debug line above and
// x509.SetFallbackRoots), so the daemon's own transport is used unchanged.
// A stand-in companion on loopback answers the daemon's status, wallet,
// lease and settlement calls from a wallet and journal that outlive its
// process and cloak-pay's: each lease leaves its request pending until a
// settlement installs the result.
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
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

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
	answered map[string]bool // destinations it serves, host:port
	tls      chan net.Conn
	mu       sync.Mutex
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
// TLS, as the destinations host:443.
func startTor(t *testing.T, issuer, inference string) *standInTor {
	leaf := standInCertificate(t, issuer, inference)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &standInTor{listener: listener, tls: make(chan net.Conn),
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
	if !s.answered[seen.destination] {
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
}

type companionState struct {
	pending, leases   int
	attempts, settled map[int]int
	calls             []string
}

// startCompanion starts the stand-in companion: the status the daemon checks,
// the wallet's state, a new lease for each request, and settlement.
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
			pending := s.pending != 0
			s.mu.Unlock()
			json.NewEncoder(w).Encode(map[string]any{"has_note": true, "pending_request": pending,
				"note": map[string]any{"note_id": 1, "current_balance": 1000000}})
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
	tor := startTor(t, hostOf(t, d.Privacy.IssuerURL), hostOf(t, zkapi.DefaultInferenceBaseURL))
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
	p, err := newPay(ctx, c, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// sentFrame is a request frame sent on a connection of its own, its answer
// still to read.
type sentFrame struct {
	host   net.Conn
	served chan error // serve's result, when the test runs serve itself
}

// send sends one request frame to p over a pipe.
func send(t *testing.T, ctx context.Context, p *pay, request any) sentFrame {
	host, guest := net.Pipe()
	served := make(chan error, 1)
	go func() { served <- p.serve(ctx, guest); guest.Close() }()
	writeRequest(t, host, request)
	return sentFrame{host, served}
}

// writeRequest writes the frame, and returns once the guest has read it.
func writeRequest(t *testing.T, host net.Conn, request any) {
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := writePayFrame(host, payRequest, payload); err != nil {
		t.Fatal(err)
	}
}

// answer reads the frame's answer and closes the connection.
func (f sentFrame) answer(t *testing.T) payAnswerFrame {
	t.Helper()
	kind, data, err := readPayFrame(f.host)
	if err != nil || kind != payAnswer {
		t.Fatalf("answer %q %v", kind, err)
	}
	f.host.Close()
	if f.served != nil {
		if err := <-f.served; err != nil {
			t.Fatal(err)
		}
	}
	var answer payAnswerFrame
	if err := json.Unmarshal(data, &answer); err != nil {
		t.Fatal(err)
	}
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
	writeRequest(t, host, request)
	return sentFrame{host: host}
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
		answer := exchange(t, ctx, p, map[string]string{"identity": identity, "body": sent[i]})
		if answer.Status != http.StatusOK || answer.Body != standInAnswer {
			t.Fatalf("answer %d: %d %s", i, answer.Status, answer.Body)
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
		if _, err := newPay(ctx, c, log.New(io.Discard, "", 0)); err == nil {
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
// companion's wait, and both are answered.
func TestCloakPayHoldsTheNextRequest(t *testing.T) {
	tor, companion, c := standIns(t)
	companion.configure(companionOptions{unfinished: true})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	p := startPay(t, ctx, c)
	first := send(t, ctx, p, ask(identity(t), "First, sent with the second."))
	second := send(t, ctx, p, ask(identity(t), "Second, sent with the first."))
	for i, frame := range []sentFrame{first, second} {
		if answer := frame.answer(t); answer.Status != http.StatusOK || answer.Body != standInAnswer {
			t.Fatalf("answer %d: %d %s", i+1, answer.Status, answer.Body)
		}
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
// would fail, as on the trip.
func TestCloakPayHoldsForAnEarlierRun(t *testing.T) {
	tor, companion, c := standIns(t)
	companion.leftPending(7)
	gate, settling := make(chan struct{}), make(chan int, 4)
	companion.configure(companionOptions{restarted: true, gate: gate, settling: settling})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := startPay(t, ctx, c)
	first := send(t, ctx, p, ask(identity(t), "First after a restart."))
	select {
	case lease := <-settling:
		if lease != 7 {
			t.Fatalf("settling lease %d", lease)
		}
	case <-time.After(10 * time.Second):
		answer := first.answer(t)
		t.Fatalf("answered with no settlement: %d %s", answer.Status, answer.Body)
	}
	if s := companion.state(); s.leases != 7 || len(tor.connections()) != 0 {
		t.Fatalf("while held, %d leases and %d connections to Tor", s.leases, len(tor.connections()))
	}
	close(gate)
	if answer := first.answer(t); answer.Status != http.StatusOK || answer.Body != standInAnswer {
		t.Fatalf("answer: %d %s", answer.Status, answer.Body)
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
	if answer := held.answer(t); answer.Status != http.StatusRequestTimeout {
		t.Fatalf("held request: %d %s", answer.Status, answer.Body)
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
