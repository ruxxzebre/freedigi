package bridge

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testService() *Service {
	s := New("/missing-helper", "test", nil)
	s.state.Path = "test-controller"
	s.state.Data["snapshot"] = Object{"device": "original", "data": "binary bytes"}
	return s
}
func TestDryRunAndSnapshotAreOwnedByBackend(t *testing.T) {
	s := testService()
	s.runner = func(req Object) (Reply, error) {
		if req["dryRun"] != true || req["path"] != "test-controller" {
			t.Fatalf("frontend changed write authority: %v", req)
		}
		snapshot := req["snapshot"].(map[string]any)
		if snapshot["device"] != "original" {
			t.Fatal("snapshot injection accepted")
		}
		if _, ok := req["arbitraryCommand"]; ok {
			t.Fatal("unknown command forwarded")
		}
		return Reply{OK: true, Result: Object{"preview": true, "message": "Validated"}}, nil
	}
	_, err := s.Perform("profileApply", Object{"dryRun": false, "snapshot": Object{}, "path": "/another-device", "arbitraryCommand": 13, "mappings": Object{"18": 4}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Status().Data["snapshot"]; !ok {
		t.Fatal("dry run lost snapshot")
	}
}
func TestAmbiguousWriteInvalidatesSnapshot(t *testing.T) {
	s := testService()
	_, _ = s.SetDryRun(false)
	calls := 0
	s.runner = func(Object) (Reply, error) { calls++; return Reply{}, errors.New("timeout after write") }
	if _, err := s.Perform("profileApply", Object{}); err == nil {
		t.Fatal("expected timeout")
	}
	if _, err := s.Perform("profileApply", Object{}); err == nil {
		t.Fatal("stale snapshot was reusable")
	}
	if calls != 1 {
		t.Fatal("retried a write without fresh read")
	}
}
func TestConcurrentOperationsAndModeChangesAreRejected(t *testing.T) {
	s := testService()
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan struct{})
	s.runner = func(Object) (Reply, error) { close(entered); <-release; return Reply{OK: true, Result: Object{}}, nil }
	go func() { defer close(done); _, _ = s.Perform("profileRead", nil) }()
	<-entered
	if _, err := s.SetDryRun(false); err == nil {
		t.Fatal("write mode changed during operation")
	}
	if _, err := s.Perform("turboRead", nil); err == nil {
		t.Fatal("overlapping HID operations allowed")
	}
	close(release)
	<-done
}
func TestDeviceSwitchClearsCachedControllerState(t *testing.T) {
	s := testService()
	s.state.Devices = []Object{{"path": "other", "accessible": true}}
	state, err := s.Select("other")
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Data) != 0 || state.MonitorWanted || state.Input != nil {
		t.Fatal("old device state retained")
	}
	if _, err = s.Perform("profileApply", Object{}); err == nil {
		t.Fatal("write allowed before fresh read")
	}
}
func TestUnknownActionsAndMissingHelperFailClosed(t *testing.T) {
	s := testService()
	if _, err := s.Perform("firmwareFlash", nil); err == nil {
		t.Fatal("unsupported flash accepted")
	}
	if _, err := s.Refresh(); err == nil {
		t.Fatal("missing service reported success")
	}
}
func TestReportOmitsRawSnapshotsAndLogsAreBounded(t *testing.T) {
	s := testService()
	for i := 0; i < 250; i++ {
		s.log("test", "entry")
	}
	if len(s.Status().Logs) != 200 {
		t.Fatal("unbounded logs")
	}
	if strings.Contains(s.Report(), "binary bytes") {
		t.Fatal("raw profile included in essential report")
	}
	if _, ok := s.Status().Data["snapshot"]; !ok {
		t.Fatal("report modified live snapshot")
	}
}

func TestMonitorFailureClearsRequestedState(t *testing.T) {
	s := testService()
	if _, err := s.Monitor(true); err == nil {
		t.Fatal("missing helper should fail")
	}
	if s.Status().MonitorWanted {
		t.Fatal("failed start still requested")
	}
	helper := filepath.Join(t.TempDir(), "helper")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s\\n' '{\"ok\":false,\"error\":\"Controller disconnected\"}'\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	s.helper = helper
	if _, err := s.Monitor(true); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	done := s.done
	s.mu.Unlock()
	<-done
	state := s.Status()
	if state.MonitorWanted || state.Monitoring || !strings.Contains(state.Error, "disconnected") {
		t.Fatalf("incorrect monitor failure state: %+v", state)
	}
	s.Close()
}

func TestPlatformGroundworkDoesNotAdvertiseWindowsHardware(t *testing.T) {
	for _, platform := range []string{"linux", "darwin"} {
		if ok, _ := platformSupport(platform); !ok {
			t.Fatalf("lost support for %s", platform)
		}
	}
	if ok, message := platformSupport("windows"); ok || !strings.Contains(message, "not implemented") {
		t.Fatal("Windows hardware support was advertised")
	}
	if serviceExecutableName("windows") != "freedigi-service.exe" || serviceExecutableName("darwin") != "freedigi-service" {
		t.Fatal("incorrect service executable suffix")
	}
}
