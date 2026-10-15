// Package bridge owns the controller service lifecycle and all mutable device state.
package bridge

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

type Object = map[string]any
type Log struct {
	Time    string `json:"time"`
	Action  string `json:"action"`
	Mode    string `json:"mode"`
	Message string `json:"message"`
}
type State struct {
	PlatformSupported bool     `json:"platformSupported"`
	PlatformMessage   string   `json:"platformMessage"`
	Platform          string   `json:"platform"`
	Devices           []Object `json:"devices"`
	Path              string   `json:"path"`
	DryRun            bool     `json:"dryRun"`
	Monitoring        bool     `json:"monitoring"`
	MonitorWanted     bool     `json:"monitorWanted"`
	Input             Object   `json:"input"`
	Data              Object   `json:"data"`
	Logs              []Log    `json:"logs"`
	Busy              string   `json:"busy"`
	Error             string   `json:"error"`
	Build             string   `json:"build"`
}
type Reply struct {
	OK     bool            `json:"ok"`
	Result Object          `json:"result"`
	Error  string          `json:"error"`
	Events json.RawMessage `json:"events"`
}
type Service struct {
	runner  func(Object) (Reply, error)
	op      sync.Mutex
	mu      sync.Mutex
	state   State
	helper  string
	emit    func(string, any)
	process *exec.Cmd
	stdin   io.WriteCloser
	done    chan struct{}
}

func New(helper, build string, emit func(string, any)) *Service {
	supported, message := platformSupport(runtime.GOOS)
	return &Service{helper: helper, emit: emit, state: State{PlatformSupported: supported, PlatformMessage: message, Devices: []Object{}, DryRun: true, Data: Object{}, Logs: []Log{}, Build: build, Platform: runtime.GOOS + "/" + runtime.GOARCH}}
}
func HelperPath() string {
	if p := os.Getenv("FREEDIGI_SERVICE"); p != "" && filepath.IsAbs(p) {
		return p
	}
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), serviceExecutableName(runtime.GOOS))
}
func clone[T any](v T) T {
	b, _ := json.Marshal(v)
	var result T
	_ = json.Unmarshal(b, &result)
	return result
}
func (s *Service) Status() State { s.mu.Lock(); defer s.mu.Unlock(); return clone(s.state) }
func (s *Service) log(action, message string) {
	s.mu.Lock()
	mode := "live"
	if s.state.DryRun {
		mode = "dry run"
	}
	s.state.Logs = append(s.state.Logs, Log{time.Now().UTC().Format(time.RFC3339), action, mode, message})
	if len(s.state.Logs) > 200 {
		s.state.Logs = s.state.Logs[len(s.state.Logs)-200:]
	}
	s.mu.Unlock()
}
func (s *Service) invoke(request Object) (Reply, error) {
	if s.runner != nil {
		return s.runner(request)
	}
	if supported, message := platformSupport(runtime.GOOS); !supported {
		return Reply{}, errors.New(message)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	payload, err := json.Marshal(request)
	if err != nil {
		return Reply{}, err
	}
	cmd := exec.CommandContext(ctx, s.helper)
	cmd.Stdin = bytes.NewReader(append(payload, '\n'))
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	data, runErr := cmd.Output()
	var reply Reply
	if err = json.Unmarshal(data, &reply); err != nil {
		if ctx.Err() != nil {
			return reply, errors.New("Controller operation exceeded its deadline. Read the device before retrying; changes may be partial.")
		}
		if runErr != nil {
			return reply, fmt.Errorf("Controller service could not run: %w. %s", runErr, strings.TrimSpace(stderr.String()))
		}
		return reply, errors.New("Invalid controller service response")
	}
	if !reply.OK {
		return reply, errors.New(reply.Error)
	}
	if runErr != nil {
		return reply, runErr
	}
	return reply, nil
}

var actions = map[string][]string{
	"profileRead": {}, "profileApply": {"mappings", "persist"}, "turboRead": {}, "turboApply": {"enabled"},
	"calibrationRead": {}, "calibrationApply": {"enabled"}, "lightingRead": {}, "lightingApply": {"color", "brightness", "off"}, "firmwareRead": {},
}
var snapshots = map[string]string{"profileApply": "snapshot", "turboApply": "turbo", "calibrationApply": "calibration", "lightingApply": "lighting"}

func (s *Service) Perform(action string, params Object) (Object, error) {
	allowed, ok := actions[action]
	if !ok {
		return nil, errors.New("Unknown controller operation")
	}
	if !s.op.TryLock() {
		return nil, errors.New("A controller operation is already in progress")
	}
	defer s.op.Unlock()
	s.mu.Lock()
	if s.state.Path == "" {
		s.mu.Unlock()
		return nil, errors.New("Select a controller first")
	}
	request := Object{"action": action, "path": s.state.Path, "dryRun": s.state.DryRun}
	for _, key := range allowed {
		if value, found := params[key]; found {
			request[key] = value
		}
	}
	if key, needed := snapshots[action]; needed {
		value, found := s.state.Data[key]
		if !found {
			s.mu.Unlock()
			return nil, errors.New("Read this setting before applying changes")
		}
		request[key] = clone(value)
	}
	resume := s.state.MonitorWanted
	s.state.Busy = action
	s.state.Error = ""
	s.mu.Unlock()
	s.stopMonitor()
	defer func() {
		s.mu.Lock()
		s.state.Busy = ""
		s.mu.Unlock()
		if resume {
			if err := s.startMonitor(); err != nil {
				s.log("Monitor resume", err.Error())
			}
		}
	}()
	s.log(action, "Started")
	reply, err := s.invoke(request)
	if len(reply.Events) > 0 && string(reply.Events) != "[]" {
		s.log(action, string(reply.Events))
	}
	if err != nil {
		s.mu.Lock()
		s.state.Error = err.Error()
		// Invalidate a possibly stale write snapshot; the next attempt requires a fresh read.
		if key, write := snapshots[action]; write {
			delete(s.state.Data, key)
		}
		s.mu.Unlock()
		s.log(action, err.Error())
		return nil, err
	}
	s.mu.Lock()
	if preview, _ := reply.Result["preview"].(bool); !preview {
		for k, v := range reply.Result {
			s.state.Data[k] = v
		}
	}
	s.mu.Unlock()
	message := "Completed and read back"
	if strings.HasSuffix(action, "Read") {
		message = "Read completed"
	}
	if preview, _ := reply.Result["preview"].(bool); preview {
		message = fmt.Sprint(reply.Result["message"])
	}
	s.log(action, message)
	return reply.Result, nil
}
func (s *Service) Refresh() (State, error) {
	if !s.op.TryLock() {
		return s.Status(), errors.New("A controller operation is in progress")
	}
	defer s.op.Unlock()
	reply, err := s.invoke(Object{"action": "devices"})
	if err != nil {
		s.log("Discovery", err.Error())
		return s.Status(), err
	}
	raw, _ := json.Marshal(reply.Result["devices"])
	devices := []Object{}
	if err = json.Unmarshal(raw, &devices); err != nil {
		return s.Status(), err
	}
	s.mu.Lock()
	s.state.Devices = devices
	path := s.state.Path
	found := false
	for _, d := range devices {
		if d["path"] == path {
			found = true
		}
	}
	if !found {
		s.state.Path = ""
		s.state.Data = Object{}
		s.state.Input = nil
		s.state.MonitorWanted = false
	}
	s.mu.Unlock()
	if !found {
		s.stopMonitor()
	}
	return s.Status(), nil
}
func (s *Service) Select(path string) (State, error) {
	if !s.op.TryLock() {
		return s.Status(), errors.New("A controller operation is in progress")
	}
	defer s.op.Unlock()
	s.mu.Lock()
	valid := path == ""
	for _, d := range s.state.Devices {
		if d["path"] == path && d["accessible"] == true {
			valid = true
		}
	}
	s.mu.Unlock()
	if !valid {
		return s.Status(), errors.New("Device is unavailable or needs the supplied udev permission rule")
	}
	s.stopMonitor()
	s.mu.Lock()
	s.state.Path = path
	s.state.Data = Object{}
	s.state.Input = nil
	s.state.MonitorWanted = false
	s.state.Error = ""
	s.mu.Unlock()
	s.log("Device", "Selected "+path)
	return s.Status(), nil
}
func (s *Service) SetDryRun(enabled bool) (State, error) {
	if !s.op.TryLock() {
		return s.Status(), errors.New("Wait for the current operation before changing dry run")
	}
	defer s.op.Unlock()
	s.mu.Lock()
	s.state.DryRun = enabled
	s.mu.Unlock()
	s.log("Dry run", fmt.Sprintf("Enabled: %t. Reads remain live.", enabled))
	return s.Status(), nil
}
func (s *Service) Monitor(enabled bool) (State, error) {
	if !s.op.TryLock() {
		return s.Status(), errors.New("A controller operation is in progress")
	}
	defer s.op.Unlock()
	s.stopMonitor()
	s.mu.Lock()
	s.state.MonitorWanted = enabled
	s.mu.Unlock()
	var err error
	if enabled {
		err = s.startMonitor()
		if err != nil {
			s.mu.Lock()
			s.state.MonitorWanted = false
			s.mu.Unlock()
		}
	}
	return s.Status(), err
}
func (s *Service) startMonitor() error {
	if supported, message := platformSupport(runtime.GOOS); !supported {
		return errors.New(message)
	}
	s.mu.Lock()
	path := s.state.Path
	s.mu.Unlock()
	if path == "" {
		return errors.New("Select a controller first")
	}
	cmd := exec.Command(s.helper)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return err
	}
	if err = cmd.Start(); err != nil {
		stdin.Close()
		return err
	}
	done := make(chan struct{})
	s.mu.Lock()
	s.process = cmd
	s.state.MonitorWanted = true
	s.stdin = stdin
	s.done = done
	s.mu.Unlock()
	payload, _ := json.Marshal(Object{"action": "monitor", "path": path})
	_, err = stdin.Write(append(payload, '\n'))
	if err != nil {
		cmd.Process.Kill()
	}
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			var event Object
			if json.Unmarshal(scanner.Bytes(), &event) != nil {
				continue
			}
			s.mu.Lock()
			if event["event"] == "input" {
				if state, ok := event["state"].(map[string]any); ok {
					s.state.Input = state
				}
			}
			if event["event"] == "monitor" {
				s.state.Monitoring = true
			}
			if event["ok"] == false {
				s.state.Error = fmt.Sprint(event["error"])
			}
			s.mu.Unlock()
			if event["ok"] == false {
				s.log("Monitor", fmt.Sprint(event["error"]))
			}
			if s.emit != nil {
				s.emit("controller", event)
			}
		}
		waitErr := cmd.Wait()
		stdin.Close()
		s.mu.Lock()
		s.state.Monitoring = false
		s.state.MonitorWanted = false
		s.state.Input = nil
		s.mu.Unlock()
		if waitErr != nil {
			s.log("Monitor stopped", waitErr.Error())
		}
		if s.emit != nil {
			s.emit("controller", Object{"event": "monitor", "running": false})
		}
	}()
	s.log("Monitor", "Starting input stream")
	return err
}
func (s *Service) stopMonitor() {
	s.mu.Lock()
	cmd, stdin, done := s.process, s.stdin, s.done
	s.mu.Unlock()
	if cmd == nil {
		return
	}
	stdin.Close() // EOF asks Swift to stop streaming and close the HID handle.
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		cmd.Process.Kill()
		<-done
	}
	s.mu.Lock()
	s.process = nil
	s.stdin = nil
	s.done = nil
	s.state.Monitoring = false
	s.state.Input = nil
	s.mu.Unlock()
}
func (s *Service) Close() { s.op.Lock(); defer s.op.Unlock(); s.stopMonitor() }
func (s *Service) Report() string {
	state := s.Status()
	delete(state.Data, "snapshot")
	delete(state.Data, "lighting")
	body, _ := json.MarshalIndent(state, "", "  ")
	return "FreeDigi diagnostic report\nWails + React; based on ControlLab Swift by dracinn.\nInput monitoring does not establish game compatibility.\nCaptured: " + time.Now().UTC().Format(time.RFC3339) + "\n" + string(body)
}
