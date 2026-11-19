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
// A stand-in companion on loopback answers the daemon's status, lease and
// settlement calls.
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
	"testing"
	"time"

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

// startCompanion starts the stand-in companion: the status the daemon checks,
// a new lease for each request, and settlement.
func startCompanion(t *testing.T, bridge string, d standInDeployment) (*httptest.Server, *int) {
	var mu sync.Mutex
	leases := 0
	companion := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+bridge {
			http.Error(w, "{}", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.Method + " " + r.URL.Path {
		case "GET /oa/v1/status":
			json.NewEncoder(w).Encode(map[string]any{"chain_id": d.ChainID, "mode": "direct_openrouter", "require_oa_org_key_source": true,
				"bridge_version": 4, "deployment_id": d.ID, "contract_address": d.Contract, "billing_asset": d.Asset,
				"billing_unit": d.Unit, "circuit_id": d.Proof.Circuit})
		case "POST /oa/v1/lease":
			mu.Lock()
			leases++
			n := leases
			mu.Unlock()
			json.NewEncoder(w).Encode(map[string]any{"api_key": fmt.Sprintf("stand-in-key-%d", n), "base_url": zkapi.DefaultInferenceBaseURL,
				"expires_at": time.Now().Unix() + 300, "verified": true, "verification_status": "verified"})
		case "POST /wallet/settle":
			fmt.Fprint(w, `{"pending_request": false}`)
		default:
			http.Error(w, "{}", http.StatusNotFound)
		}
	}))
	t.Cleanup(companion.Close)
	return companion, &leases
}

// exchange sends one request frame to p over a pipe and reads its answer.
func exchange(t *testing.T, ctx context.Context, p *pay, request any) payAnswerFrame {
	host, guest := net.Pipe()
	defer host.Close()
	served := make(chan error, 1)
	go func() { served <- p.serve(ctx, guest); guest.Close() }()
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := writePayFrame(host, payRequest, payload); err != nil {
		t.Fatal(err)
	}
	kind, data, err := readPayFrame(host)
	if err != nil || kind != payAnswer {
		t.Fatalf("answer %q %v", kind, err)
	}
	host.Close()
	if err := <-served; err != nil {
		t.Fatal(err)
	}
	var answer payAnswerFrame
	if err := json.Unmarshal(data, &answer); err != nil {
		t.Fatal(err)
	}
	return answer
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
	tor := startTor(t, issuer, inference)
	bridge := strings.Repeat("b", 64)
	companion, leases := startCompanion(t, bridge, d)
	before := listening(t)
	stands := []string{tor.listener.Addr().String(), companion.Listener.Addr().String()}
	sort.Strings(stands)
	if !reflect.DeepEqual(before, stands) {
		t.Fatalf("before cloak-pay, listening %v, want the stand-ins %v", before, stands)
	}

	c, err := payConfig()
	if err != nil {
		t.Fatal(err)
	}
	c.RelayURL = "tor://" + tor.listener.Addr().String()
	c.ZKAPI.ClientURL = companion.URL
	c.ZKAPI.BridgeToken = bridge
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p, err := newPay(ctx, c, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	a, _ := relay.NewTorIdentity()
	b, _ := relay.NewTorIdentity()
	sent := []string{chat("First conversation."), chat("Second conversation.")}
	for i, identity := range []string{a, b} {
		answer := exchange(t, ctx, p, map[string]string{"identity": identity, "body": sent[i]})
		if answer.Status != http.StatusOK || answer.Body != standInAnswer {
			t.Fatalf("answer %d: %d %s", i, answer.Status, answer.Body)
		}
	}

	// A frame without a conversation's identity is refused, and nothing
	// leaves for it.
	seenBefore, leasesBefore := len(tor.connections()), *leases
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
	if len(tor.connections()) != seenBefore || *leases != leasesBefore {
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
	if len(tor.keys) != 2 || tor.keys[0] == tor.keys[1] {
		t.Fatalf("provider keys %v", tor.keys)
	}
	for i, body := range tor.bodies {
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
