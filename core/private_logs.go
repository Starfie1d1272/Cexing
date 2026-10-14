package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const privateLogHeader = "CEXING_REDACTED_LOG_V1\n"

const logFileMaxBytes = 2 * 1024 * 1024
const logRetention = 7 * 24 * time.Hour

var logFileMu sync.Mutex
var logToFileEnabled = true
var logSessionActive bool
var logNeedsMaintenance bool
var logRetryAfter time.Time

// Use the existing process-lifetime config dictionary, including rejected and
// previous candidates. If it cannot be obtained, fail closed on free text.
func redactOrdinaryLog(input string) string {
	s, err := getDiagnosticStore(diagnosticKernelDirectory(), "kernel")
	if err != nil {
		return "DETAIL_OMITTED_REDACTION_UNAVAILABLE"
	}
	return s.text(input)
}

func openPrivateLog(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_CREAT|unix.O_APPEND|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0o600)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	var st unix.Stat_t
	if err = unix.Fstat(fd, &st); err == nil && (st.Mode&unix.S_IFMT != unix.S_IFREG || st.Nlink != 1 || st.Uid != uint32(os.Getuid())) {
		err = unix.EPERM
	}
	if err == nil {
		err = f.Chmod(0o600)
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	if strings.HasSuffix(path, ".lock") {
		return f, nil
	}
	// Discard legacy raw generations before they can be retained by rotation.
	header := make([]byte, len(privateLogHeader))
	n, readErr := f.ReadAt(header, 0)
	if readErr != nil && readErr != io.EOF {
		f.Close()
		return nil, readErr
	}
	if string(header[:n]) != privateLogHeader || st.Size > logFileMaxBytes {
		if err = f.Truncate(0); err == nil {
			_, err = f.WriteString(privateLogHeader)
		}
		if err != nil {
			f.Close()
			return nil, err
		}
	}
	return f, nil
}

func lockPrivateLogs(home string) (*os.File, error) {
	lock, err := openPrivateLog(filepath.Join(home, ".mihomo-log.lock"))
	if err != nil {
		return nil, err
	}
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		return nil, err
	}

	return lock, nil
}

func maintainPrivateLogs(home string, now time.Time) error {
	path := filepath.Join(home, "mihomo.log")
	for _, name := range []string{path, path + ".old"} {
		if st, e := os.Lstat(name); e == nil && now.Sub(st.ModTime()) > logRetention {
			if e = os.Remove(name); e != nil {
				return e
			}
		} else if e == nil {
			legacy, err := openPrivateLog(name)
			if err != nil {
				return err
			}
			legacy.Close()
		}
	}
	return nil
}

// Open per write under a cross-process lock: no stale descriptor can continue
// appending to a renamed generation. Contention drops a file line, never waits
// for the other process. Errors back off instead of retrying on every event.
func appendPrivateLog(home, line string, now time.Time) error {
	if len(line)+len(privateLogHeader)+1 > logFileMaxBytes {
		return unix.EFBIG
	}
	lock, err := lockPrivateLogs(home)
	if err != nil {
		return err
	}
	defer lock.Close()
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	if err := maintainPrivateLogs(home, now); err != nil {
		return err
	}
	path := filepath.Join(home, "mihomo.log")
	f, err := openPrivateLog(path)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	if st.Size()+int64(len(line)+1) > logFileMaxBytes {
		f.Close()
		if err = os.Rename(path, path+".old"); err != nil {
			return err
		}
		f, err = openPrivateLog(path)
		if err != nil {
			return err
		}
	}
	defer f.Close()
	_, err = f.WriteString(line + "\n")
	return err
}

func writeLogLine(line string) {
	// Redact before truncation or disk I/O, including callers outside the relay.
	line = redactOrdinaryLog(line)
	logFileMu.Lock()
	defer logFileMu.Unlock()
	now := time.Now()
	if !logSessionActive || now.Before(logRetryAfter) {
		return
	}
	if logNeedsMaintenance {
		lock, err := lockPrivateLogs(homeDir)
		if err == nil {
			err = maintainPrivateLogs(homeDir, now)
			unix.Flock(int(lock.Fd()), unix.LOCK_UN)
			lock.Close()
		}
		if err != nil {
			logRetryAfter = now.Add(30 * time.Second)
			return
		}
		logNeedsMaintenance = false
	}
	if !logToFileEnabled {
		return
	}
	if err := appendPrivateLog(homeDir, line, now); err != nil {
		logRetryAfter = now.Add(30 * time.Second)
	}
}

// This switch controls only ordinary Mihomo file logging, not hilog, stderr
// failure metadata or the separately bounded, structured diagnostic journal.
func setLogToFile(enabled bool) {
	logFileMu.Lock()
	defer logFileMu.Unlock()
	logToFileEnabled = enabled
}
