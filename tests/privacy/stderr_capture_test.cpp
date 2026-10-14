#include "stderr_capture.h"
#include <cassert>
#include <fstream>
#include <sys/wait.h>
#include <vector>

static std::string readText(const std::string &path) {
    std::ifstream file(path);
    return std::string(std::istreambuf_iterator<char>(file), {});
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::string home = argv[1];
    int dir = open(home.c_str(), O_RDONLY | O_DIRECTORY);
    assert(dir >= 0);
    for (int n = 0; n < 9000; ++n) assert(stderr_capture::append(dir, "panic: private-secret", time(nullptr)));
    std::vector<pid_t> children;
    for (int i = 0; i < 2; ++i) {
        pid_t pid = fork();
        assert(pid >= 0);
        if (pid == 0) {
            for (int n = 0; n < 12000; ++n)
                stderr_capture::append(dir, "panic: https://user:password@private.example/path?token=private-secret 192.0.2.1", time(nullptr));
            _exit(0);
        }
        children.push_back(pid);
    }
    for (pid_t pid : children) { int status; assert(waitpid(pid, &status, 0) == pid && status == 0); }
    for (const char *name : {"go_stderr.log", "go_stderr.log.old"}) {
        std::string path = home + "/" + name;
        struct stat st {};
        assert(stat(path.c_str(), &st) == 0 && st.st_size <= stderr_capture::MaxBytes && (st.st_mode & 0777) == 0600);
        std::string text = readText(path);
        assert(text.find("go_panic detail_omitted") != std::string::npos && text.find("password") == std::string::npos && text.find("192.0.2.1") == std::string::npos);
    }
    // Failed rotation/alias handling cannot follow a target or block on FIFO.
    unlinkat(dir, "go_stderr.log", 0);
    std::string victim = home + "/victim";
    { std::ofstream out(victim); out << "untouched"; }
    assert(symlink(victim.c_str(), (home + "/go_stderr.log").c_str()) == 0);
    assert(!stderr_capture::append(dir, "private", time(nullptr)));
    assert(readText(victim) == "untouched");
    unlinkat(dir, "go_stderr.log", 0);
    assert(mkfifoat(dir, "go_stderr.log", 0600) == 0);
    assert(!stderr_capture::append(dir, "private", time(nullptr)));
    unlinkat(dir, "go_stderr.log", 0);
    assert(stderr_capture::append(dir, "fatal error: private", time(nullptr)));
    timespec old[2] = {{time(nullptr) - stderr_capture::Retention - 1, 0}, {time(nullptr) - stderr_capture::Retention - 1, 0}};
    assert(utimensat(dir, "go_stderr.log.old", old, 0) == 0);
    assert(stderr_capture::append(dir, "private", time(nullptr)));
    struct stat st {};
    assert(fstatat(dir, "go_stderr.log.old", &st, 0) != 0 && errno == ENOENT);
    close(dir);
    assert(!stderr_capture::start("relative/private"));
    assert(!stderr_capture::start(home + "/missing"));
    // Exercise the actual nonblocking pipe path, including split and long lines.
    assert(stderr_capture::start(home));
    std::string flood(1024 * 1024, 'x'); flood += "\n";
    (void)write(STDERR_FILENO, flood.data(), flood.size());
    (void)write(STDERR_FILENO, "\npanic: private-secret\n", 23);
    for (int i=0; i<200; ++i) {
        (void)write(STDERR_FILENO, "\n", 1);
        if (readText(home + "/runtime-logs/go_stderr.log").find("detail_omitted") != std::string::npos) return 0;
        usleep(10000);
    }
    assert(false && "pipe consumer did not record sanitized metadata");
}
