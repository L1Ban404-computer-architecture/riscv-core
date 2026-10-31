#include "process.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/wait.h>
#include <unistd.h>

namespace sim {

std::filesystem::path CoreDirectory() { return SIM_CORE_DIR; }

void RunCommand(const std::vector<std::string> &arguments, const std::filesystem::path &log) {
  if (arguments.empty()) throw std::invalid_argument("empty command");
  std::filesystem::create_directories(log.parent_path());
  std::vector<char *> argv;
  for (const auto &argument : arguments) argv.push_back(const_cast<char *>(argument.c_str()));
  argv.push_back(nullptr);
  const pid_t child = fork();
  if (child < 0) throw std::runtime_error("fork failed: " + std::string(std::strerror(errno)));
  if (child == 0) {
    const int fd = open(log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0 || dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) _exit(126);
    if (fd > STDERR_FILENO) close(fd);
    // 子 make 是独立构建，不能继承宿主 make 的目标参数、dry-run 或 jobserver 状态。
    for (const char *name : {"MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES"}) unsetenv(name);
    execvp(argv[0], argv.data());
    dprintf(STDERR_FILENO, "exec %s failed: %s\n", argv[0], std::strerror(errno));
    _exit(127);
  }
  int status;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) throw std::runtime_error("waitpid failed: " + std::string(std::strerror(errno)));
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    throw std::runtime_error(arguments.front() + " failed; see " + log.string());
}
}  // namespace sim
