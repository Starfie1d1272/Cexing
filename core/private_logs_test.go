package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestPrivateLogPrivacyAndBounds(t *testing.T) {
	home := t.TempDir()
	s, err := getDiagnosticStore(home, "kernel")
	if err != nil {
		t.Fatal(err)
	}
	s.registerPrivateConfig(map[string]any{"proxies": []any{map[string]any{"name": "SyntheticPrivateNode", "password": "SyntheticPrivatePassword"}}})
	diagnosticKernelHome.Store(home)
	defer diagnosticKernelHome.Store("")
	logFileMu.Lock()
	oldHome := homeDir
	homeDir = home
	logSessionActive = true
	logRetryAfter = time.Time{}
	logFileMu.Unlock()
	defer func() { logFileMu.Lock(); homeDir = oldHome; logFileMu.Unlock() }()
	setLogToFile(true)
	// Existing releases' raw generations must not survive migration or rotation.
	for _, name := range []string{"mihomo.log", "mihomo.log.old"} {
		if err := os.WriteFile(filepath.Join(home, name), []byte("legacy-private-data"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	encoded := base64.StdEncoding.EncodeToString([]byte("SyntheticFileUser:SyntheticFilePassword"))
	writeLogLine("SyntheticPrivateNode SyntheticPrivatePassword Bearer SyntheticBearer https://user:password@sub.example/private?token=secret 192.0.2.1 [2001:db8::1] 2001:db8::2 fe80::a%wlan0 Proxy-Authorization: Basic " + encoded)
	data, err := os.ReadFile(filepath.Join(home, "mihomo.log"))
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"SyntheticPrivateNode", "SyntheticPrivatePassword", "SyntheticBearer", "sub.example", "192.0.2.1", "2001:db8::1", "2001:db8::2", "fe80::a%wlan0", "legacy-private-data", encoded} {
		if strings.Contains(string(data), value) {
			t.Fatal("private value survived ordinary log redaction")
		}
	}
	setLogToFile(false)
	before, _ := os.ReadFile(filepath.Join(home, "mihomo.log"))
	writeLogLine("disabled")
	after, _ := os.ReadFile(filepath.Join(home, "mihomo.log"))
	setLogToFile(true)
	if string(before) != string(after) {
		t.Fatal("disabled file logger wrote a line")
	}
	logFileMu.Lock()
	logSessionActive = false // isolate direct writer stress from the process relay
	logFileMu.Unlock()
	for i := 0; i < 2200; i++ {
		if err := appendPrivateLog(home, strings.Repeat("x", 2048), time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"mihomo.log", "mihomo.log.old"} {
		st, err := os.Stat(filepath.Join(home, name))
		if err != nil || st.Size() > logFileMaxBytes || st.Mode().Perm() != 0600 {
			t.Fatalf("unbounded or unprotected %s: %v", name, err)
		}
	}
	old := time.Now().Add(-logRetention - time.Hour)
	if err := os.Chtimes(filepath.Join(home, "mihomo.log.old"), old, old); err != nil {
		t.Fatal(err)
	}
	if err := appendPrivateLog(home, "new session", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, "mihomo.log.old")); !os.IsNotExist(err) {
		t.Fatal("expired generation retained")
	}
}

func TestPrivateLogRejectsAliasesAndContention(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink", "fifo"} {
		t.Run(kind, func(t *testing.T) {
			home := t.TempDir()
			victim := filepath.Join(t.TempDir(), "victim")
			os.WriteFile(victim, []byte("untouched"), 0600)
			path := filepath.Join(home, "mihomo.log")
			var err error
			switch kind {
			case "symlink":
				err = os.Symlink(victim, path)
			case "hardlink":
				err = os.Link(victim, path)
			case "fifo":
				err = unix.Mkfifo(path, 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err = appendPrivateLog(home, "safe", time.Now()); err == nil {
				t.Fatal("unsafe target accepted")
			}
			data, _ := os.ReadFile(victim)
			if string(data) != "untouched" {
				t.Fatal("alias changed target")
			}
		})
	}
	home := t.TempDir()
	lock, err := openPrivateLog(filepath.Join(home, ".mihomo-log.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	if err = appendPrivateLog(home, "contended", time.Now()); err == nil {
		t.Fatal("concurrent writer bypassed lock")
	}
}
