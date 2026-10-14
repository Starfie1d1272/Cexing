#ifndef CEXING_STDERR_CAPTURE_H
#define CEXING_STDERR_CAPTURE_H

#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <fcntl.h>
#include <pthread.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// Raw stderr precedes Go's config redaction dictionary. Persist only fixed
// event classes, never panic values, stack arguments, paths or arbitrary text.
// This is local crash metadata; shareable evidence remains the diagnostic JSON.
namespace stderr_capture {
constexpr off_t MaxBytes = 256 * 1024;
constexpr time_t Retention = 7 * 24 * 60 * 60;

inline const char *classify(const std::string &line) {
    if (line.compare(0, 7, "panic: ") == 0) return "go_panic detail_omitted";
    if (line.compare(0, 13, "fatal error: ") == 0) return "go_fatal detail_omitted";
    if (line.compare(0, 10, "goroutine ") == 0) return "go_traceback detail_omitted";
    return "stderr detail_omitted";
}

inline int openFile(int dir, const char *name) {
    int fd = openat(dir, name, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (fd < 0) return -1;
    struct stat st {};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 || fchmod(fd, 0600) != 0) {
        close(fd);
        return -1;
    }
    if (st.st_size > MaxBytes && ftruncate(fd, 0) != 0) { close(fd); return -1; }
    return fd;
}

inline bool append(int dir, const std::string &line, time_t now) {
    int lock = openFile(dir, ".stderr.lock");
    if (lock < 0) return false;
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) { close(lock); return false; }
    bool ok = true;
    for (const char *name : {"go_stderr.log", "go_stderr.log.old"}) {
        struct stat st {};
        if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && now - st.st_mtime > Retention) {
            if (unlinkat(dir, name, 0) != 0) ok = false;
        } else if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
            int existing = openFile(dir, name);
            if (existing < 0) ok = false;
            else close(existing);
        }
    }
    int fd = ok ? openFile(dir, "go_stderr.log") : -1;
    std::string record = std::to_string(now) + " " + classify(line) + "\n";
    struct stat st {};
    if (fd >= 0 && fstat(fd, &st) == 0) {
        if (st.st_size + static_cast<off_t>(record.size()) > MaxBytes) {
            close(fd);
            fd = -1;
            if (renameat(dir, "go_stderr.log", dir, "go_stderr.log.old") == 0) fd = openFile(dir, "go_stderr.log");
        }
        ok = fd >= 0 && write(fd, record.data(), record.size()) == static_cast<ssize_t>(record.size());
    } else ok = false;
    if (fd >= 0) close(fd);
    flock(lock, LOCK_UN);
    close(lock);
    return ok;
}

struct Reader { int pipe; int directory; };
inline void *consume(void *arg) {
    Reader reader = *static_cast<Reader *>(arg);
    delete static_cast<Reader *>(arg);
    char buffer[4096];
    std::string line;
    time_t retryAfter = 0;
    ssize_t count;
    while ((count = read(reader.pipe, buffer, sizeof(buffer))) != 0) {
        if (count < 0) { if (errno == EINTR) continue; break; }
        for (ssize_t i = 0; i < count; ++i) {
            if (buffer[i] == '\n') {
                time_t now = time(nullptr);
                if (now >= retryAfter && !append(reader.directory, line, now)) retryAfter = now + 30;
                line.clear();
            } else if (line.size() < 512) line += buffer[i];
        }
    }
    if (!line.empty()) append(reader.directory, line, time(nullptr));
    close(reader.pipe);
    close(reader.directory);
    return nullptr;
}

inline bool start(const std::string &home) {
    if (home.empty() || home[0] != '/') return false;
    char *canonical = realpath(home.c_str(), nullptr);
    if (canonical == nullptr) return false;
    bool same = home == canonical;
    free(canonical);
    if (!same) return false;
    int root = open(home.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat st {};
    if (root < 0) return false;
    if (fstat(root, &st) != 0 || st.st_uid != getuid() || (st.st_mode & 0022) != 0) { close(root); return false; }
    // Remove the old unbounded raw file; it is never a support-bundle source.
    unlinkat(root, "go_stderr.log", 0);
    if (mkdirat(root, "runtime-logs", 0700) != 0 && errno != EEXIST) { close(root); return false; }
    int dir = openat(root, "runtime-logs", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(root);
    if (dir < 0) return false;
    if (fstat(dir, &st) != 0 || st.st_uid != getuid() || fchmod(dir, 0700) != 0) { close(dir); return false; }
    int pipes[2];
    if (pipe(pipes) != 0) { close(dir); return false; }
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipes[1], F_SETFD, FD_CLOEXEC);
    // A full pipe must not block Go init, a fatal writer or the VPN worker.
    if (fcntl(pipes[1], F_SETFL, O_NONBLOCK) != 0) { close(pipes[0]); close(pipes[1]); close(dir); return false; }
    auto *reader = new Reader{pipes[0], dir};
    pthread_t thread;
    if (pthread_create(&thread, nullptr, consume, reader) != 0) {
        delete reader; close(pipes[0]); close(pipes[1]); close(dir); return false;
    }
    pthread_detach(thread);
    bool ok = dup2(pipes[1], STDERR_FILENO) >= 0;
    close(pipes[1]); // on dup failure, consumer sees EOF and releases its resources
    return ok;
}
} // namespace stderr_capture
#endif
