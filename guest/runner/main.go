// Command cloak-runner runs the owner's agent tasks in a guest that serves
// (decision 12 in docs/plan.md): Pi in the reference sandbox
// (reference/wrapper/sandbox, bubblewrap and then torsocks) as the agent
// user, its model requests going to the door port (127.0.0.1:8742) and so to
// the app's door on the Mac, and everything else it and its tools open going
// through the Tor port.
//
// It listens on vsock port 8030, for the host (CID 2) only. One connection is
// one task, in frames of a kind byte, a 4-byte big-endian length and the
// payload. The host sends one frame:
//
//	T  {"task": "...", "session": "...", "model": "...", "pass": "..."}
//
// and the runner answers with these:
//
//	O  one line Pi wrote to standard output (in its JSON mode, one event), without the line end
//	E  one line written to standard error, without the line end
//	X  {"status": 0, "signalled": false}: how the task ended; the last frame
//	N  "busy" or "invalid": refused, and nothing ran; the only frame
//
// Each conversation (session) has its own home and workspace under
// /home/agent/conversations/<session>, kept until the guest ends; Pi's
// --session-id starts its session there, and continues it in the
// conversation's next task. One task at a time in a conversation, and any
// number of conversations side by side. Each task has its own copy of the
// wrapper, in /run/cloak-runner/<session>, whose models.json names the door
// and carries the task's pass, and which is removed when the task ends. The
// sandbox binds that models.json, read-only, where Pi reads it in the
// conversation's home, so the pass is never written into the home, and no
// two tasks running at once ever share the file. The task text reaches Pi on
// its standard input, never on a command line. When the host closes the
// connection, the task's sandbox is killed, and every process in it with it.
//
// Nothing of a task's text, pass or output is logged: only how each task
// ended, and how long it took.
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/mdlayher/vsock"
)

const (
	port               = 8030
	hostCID            = 2
	agentUID, agentGID = 1005, 1005
	agentHome          = "/home/agent"
	conversations      = "/home/agent/conversations"
	wrapper            = "/opt/cloak/wrapper"
	copies             = "/run/cloak-runner"
	// The door's own limit on a request's body, which carries the task.
	maxRequest = 4 << 20
	// The host's limit on a frame.
	maxLine = 16 << 20
	// How long the host has to send the task once it has connected.
	requestLimit = 10 * time.Second
	door         = "http://127.0.0.1:8742/v1"
)

var (
	// Pi's rule for a session id, and a bound on its length.
	sessionID = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$`)
	// A box pass, as the door makes it.
	boxPass = regexp.MustCompile(`^cloak-[0-9a-f]{64}$`)
)

type request struct {
	Task    string `json:"task"`
	Session string `json:"session"`
	Model   string `json:"model"`
	Pass    string `json:"pass"`
}

type exit struct {
	Status    int  `json:"status"`
	Signalled bool `json:"signalled"`
}

func (e exit) String() string {
	if e.Signalled {
		return fmt.Sprintf("signal %d", e.Status)
	}
	return fmt.Sprintf("exit status %d", e.Status)
}

// The conversations with a task under way.
var (
	busyLock sync.Mutex
	busy     = map[string]bool{}
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("cloak-runner: ")
	if err := os.Mkdir(copies, 0o711); err != nil {
		log.Fatal(err)
	}
	ln, err := vsock.Listen(port, nil)
	if err != nil {
		log.Fatal(err)
	}
	// The guest's boot waits for this one line before it goes on.
	fmt.Println("ready")
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go serve(conn)
	}
}

func serve(conn net.Conn) {
	defer conn.Close()
	if peer, ok := conn.RemoteAddr().(*vsock.Addr); !ok || peer.ContextID != hostCID {
		return
	}
	out := &frames{conn: conn}
	_ = conn.SetReadDeadline(time.Now().Add(requestLimit))
	task, ok := read(conn)
	if !ok {
		log.Print("refused a task that did not read")
		out.send('N', []byte("invalid"))
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	if !claim(task.Session) {
		log.Print("refused a task while its conversation has one under way")
		out.send('N', []byte("busy"))
		return
	}
	started := time.Now()
	ended, err := run(conn, out, task)
	// The conversation takes its next task as soon as the host has this one's end.
	release(task.Session)
	if err != nil {
		log.Printf("cannot run a task: %v", err)
		return
	}
	payload, _ := json.Marshal(ended)
	out.send('X', payload)
	log.Printf("task ended (%s) after %.1f s", ended, time.Since(started).Seconds())
}

func claim(session string) bool {
	busyLock.Lock()
	defer busyLock.Unlock()
	if busy[session] {
		return false
	}
	busy[session] = true
	return true
}

func release(session string) {
	busyLock.Lock()
	defer busyLock.Unlock()
	delete(busy, session)
}

// read takes the one task frame, and checks it.
func read(conn net.Conn) (request, bool) {
	var task request
	head := make([]byte, 5)
	if _, err := io.ReadFull(conn, head); err != nil || head[0] != 'T' {
		return task, false
	}
	length := binary.BigEndian.Uint32(head[1:])
	if length > maxRequest {
		return task, false
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return task, false
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&task) != nil {
		return task, false
	}
	if _, err := decoder.Token(); err != io.EOF {
		return task, false
	}
	// Pi trims its input as JavaScript trims, which also takes U+FEFF, and
	// runs nothing for a blank one.
	blank := strings.TrimFunc(task.Task, func(r rune) bool { return unicode.IsSpace(r) || r == 0xFEFF }) == ""
	model := task.Model != "" && len(task.Model) <= 256 && utf8.ValidString(task.Model) &&
		strings.TrimSpace(task.Model) == task.Model && !strings.ContainsFunc(task.Model, unicode.IsControl)
	return task, !blank && model && sessionID.MatchString(task.Session) && boxPass.MatchString(task.Pass)
}

// run runs the task until it ends, sending its lines as they come, and
// removes its copy of the wrapper. Returns how it ended, or why it could not
// run.
func run(conn net.Conn, out *frames, task request) (exit, error) {
	home, workspace, copied, err := prepare(task)
	if copied != "" {
		defer os.RemoveAll(copied)
	}
	if err != nil {
		return exit{}, err
	}
	cmd := exec.Command(copied+"/sandbox", workspace,
		"pi", "--provider", "cloak", "--model", task.Model, "--mode", "json", "--session-id", task.Session)
	cmd.Dir = agentHome
	cmd.Env = []string{"HOME=" + agentHome, "PATH=/usr/bin", "TERM=dumb", "PI_PARANOID_HOME=" + home}
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: agentUID, Gid: agentGID, Groups: []uint32{}}, Setsid: true}
	cmd.Stdin = strings.NewReader(task.Task)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return exit{}, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return exit{}, err
	}
	if err := cmd.Start(); err != nil {
		return exit{}, err
	}
	// The host sends nothing more: the connection's end, or anything else,
	// ends the task. Killing the sandbox's bubblewrap (the sandbox script
	// execs it) kills the namespace's first process (--die-with-parent), and
	// with it every process in the sandbox. Once the task has been waited
	// for, this kills nothing.
	go func() {
		_, _ = conn.Read(make([]byte, 1))
		_ = cmd.Process.Kill()
	}()
	var lines sync.WaitGroup
	lines.Add(2)
	go func() { defer lines.Done(); out.lines('O', stdout, cmd.Process) }()
	go func() { defer lines.Done(); out.lines('E', stderr, cmd.Process) }()
	lines.Wait()
	_ = cmd.Wait()
	status := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if status.Signaled() {
		return exit{Status: int(status.Signal()), Signalled: true}, nil
	}
	return exit{Status: status.ExitStatus()}, nil
}

// prepare makes the conversation's home and workspace when it has none, and
// the task's copy of the wrapper. It returns the copy's folder once it has
// made it, so that it is removed whatever follows.
func prepare(task request) (home, workspace, copied string, err error) {
	conversation := filepath.Join(conversations, task.Session)
	home, workspace = filepath.Join(conversation, "home"), filepath.Join(conversation, "workspace")
	for _, dir := range []string{conversations, conversation, home, workspace} {
		if err = agentFolder(dir); err != nil {
			return
		}
	}
	folder := filepath.Join(copies, task.Session)
	if err = agentFolder(folder); err != nil {
		return
	}
	copied = folder
	sandbox, err := os.ReadFile(filepath.Join(wrapper, "sandbox"))
	if err != nil {
		return
	}
	torsocks, err := os.ReadFile(filepath.Join(wrapper, "torsocks.conf"))
	if err != nil {
		return
	}
	// Give every agent conversation its own Tor circuit for tool egress via
	// IsolateSOCKSAuth, rather than sharing an unauthenticated circuit.
	torsocks = append(torsocks, []byte(fmt.Sprintf("\nSOCKS5Username cloak-agent-%s\nSOCKS5Password cloak\n", task.Session))...)
	models, err := json.Marshal(map[string]any{"providers": map[string]any{"cloak": map[string]any{
		"baseUrl": door, "api": "openai-completions", "apiKey": task.Pass,
		"models": []map[string]any{{"id": task.Model}},
	}}})
	if err != nil {
		return
	}
	for _, file := range []struct {
		name string
		data []byte
		mode os.FileMode
	}{{"sandbox", sandbox, 0o700}, {"torsocks.conf", torsocks, 0o600}, {"models.json", models, 0o600}} {
		if err = agentFile(filepath.Join(folder, file.name), file.data, file.mode); err != nil {
			return
		}
	}
	return
}

// agentFolder makes an owner-only folder of the agent's, or makes one that
// is there the agent's.
func agentFolder(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return os.Lchown(path, agentUID, agentGID)
}

func agentFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	if closed := file.Close(); err == nil {
		err = closed
	}
	if err != nil {
		return err
	}
	return os.Chown(path, agentUID, agentGID)
}

// frames writes to the host, one frame at a time.
type frames struct {
	lock sync.Mutex
	conn net.Conn
}

// send writes one frame; a host that has gone fails it, and its end has
// already ended the task.
func (f *frames) send(kind byte, payload []byte) {
	f.lock.Lock()
	defer f.lock.Unlock()
	head := []byte{kind, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(head[1:], uint32(len(payload)))
	_, _ = f.conn.Write(append(head, payload...))
}

// lines sends each line read from `from` as one frame of `kind`. A line
// over the host's frame limit ends the task, which is killed rather than its
// line cut; the rest is read and dropped.
func (f *frames) lines(kind byte, from io.Reader, process *os.Process) {
	reader := bufio.NewReaderSize(from, 64<<10)
	var line []byte
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(line)+len(chunk) > maxLine {
			log.Printf("ended a task that wrote a line over %d bytes", maxLine)
			_ = process.Kill()
			_, _ = io.Copy(io.Discard, reader)
			return
		}
		line = append(line, chunk...)
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if len(line) > 0 {
			f.send(kind, bytes.TrimSuffix(line, []byte("\n")))
		}
		line = line[:0]
		if err != nil {
			return
		}
	}
}
