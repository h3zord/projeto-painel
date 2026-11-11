#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

pid_t brain_panel_pty_spawn(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int master_fd,
    int slave_fd,
    int32_t *out_errno
);

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) {
    return -1;
  }
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void write_errno_and_exit(int pipe_fd, int32_t err_code, int exit_status)
    __attribute__((noreturn));

static void write_errno_and_exit(int pipe_fd, int32_t err_code, int exit_status) {
  int32_t code = err_code != 0 ? err_code : EIO;
  const uint8_t *cursor = (const uint8_t *)&code;
  size_t remaining = sizeof(code);

  while (remaining > 0) {
    ssize_t written = write(pipe_fd, cursor, remaining);
    if (written > 0) {
      cursor += (size_t)written;
      remaining -= (size_t)written;
    } else if (written < 0 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }

  (void)close(pipe_fd);
  _exit(exit_status);
}

pid_t brain_panel_pty_spawn(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int master_fd,
    int slave_fd,
    int32_t *out_errno
) {
  if (executable_path == NULL || argv == NULL || envp == NULL || working_directory == NULL
      || slave_fd < 0) {
    if (out_errno != NULL) {
      *out_errno = EINVAL;
    }
    return -1;
  }

  int max_fd = 4096;
  struct rlimit nofile_limit;
  if (getrlimit(RLIMIT_NOFILE, &nofile_limit) == 0 && nofile_limit.rlim_cur != RLIM_INFINITY) {
    if (nofile_limit.rlim_cur > 65536) {
      max_fd = 65536;
    } else if (nofile_limit.rlim_cur > 3) {
      max_fd = (int)nofile_limit.rlim_cur;
    }
  }

  int err_pipe[2] = {-1, -1};
  if (pipe(err_pipe) != 0) {
    if (out_errno != NULL) {
      *out_errno = errno;
    }
    return -1;
  }

  if (set_cloexec(err_pipe[0]) != 0 || set_cloexec(err_pipe[1]) != 0) {
    int saved_err = errno;
    (void)close(err_pipe[0]);
    (void)close(err_pipe[1]);
    if (out_errno != NULL) {
      *out_errno = saved_err;
    }
    return -1;
  }

  if (master_fd >= max_fd) {
    max_fd = master_fd + 1;
  }
  if (slave_fd >= max_fd) {
    max_fd = slave_fd + 1;
  }
  if (err_pipe[0] >= max_fd) {
    max_fd = err_pipe[0] + 1;
  }
  if (err_pipe[1] >= max_fd) {
    max_fd = err_pipe[1] + 1;
  }

  pid_t pid = fork();
  if (pid < 0) {
    int saved_err = errno;
    (void)close(err_pipe[0]);
    (void)close(err_pipe[1]);
    if (out_errno != NULL) {
      *out_errno = saved_err;
    }
    return -1;
  }

  if (pid == 0) {
    (void)close(err_pipe[0]);
    if (master_fd >= 0 && master_fd != slave_fd && master_fd != err_pipe[1]) {
      (void)close(master_fd);
    }

    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    (void)sigprocmask(SIG_SETMASK, &empty_mask, NULL);

    struct sigaction default_action;
    sigemptyset(&default_action.sa_mask);
    default_action.sa_flags = 0;
    default_action.sa_handler = SIG_DFL;
    const int reset_signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGALRM, SIGCHLD};
    for (size_t i = 0; i < sizeof(reset_signals) / sizeof(reset_signals[0]); i++) {
      (void)sigaction(reset_signals[i], &default_action, NULL);
    }

    if (setsid() < 0) {
      write_errno_and_exit(err_pipe[1], errno, 126);
    }

    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) {
      write_errno_and_exit(err_pipe[1], errno, 126);
    }

    for (int target_fd = 0; target_fd <= 2; target_fd++) {
      if (slave_fd != target_fd) {
        while (dup2(slave_fd, target_fd) < 0) {
          if (errno != EINTR) {
            write_errno_and_exit(err_pipe[1], errno, 126);
          }
        }
      } else {
        int flags = fcntl(target_fd, F_GETFD);
        if (flags >= 0 && (flags & FD_CLOEXEC) != 0) {
          (void)fcntl(target_fd, F_SETFD, flags & ~FD_CLOEXEC);
        }
      }
    }

    for (int fd = 3; fd < max_fd; fd++) {
      if (fd != err_pipe[1]) {
        (void)close(fd);
      }
    }

    if (chdir(working_directory) != 0) {
      write_errno_and_exit(err_pipe[1], errno, 126);
    }

    (void)execve(executable_path, argv, envp);
    write_errno_and_exit(err_pipe[1], errno, 127);
  }

  (void)close(err_pipe[1]);

  int32_t child_err = 0;
  uint8_t *dest = (uint8_t *)&child_err;
  size_t total_read = 0;
  while (total_read < sizeof(child_err)) {
    ssize_t count = read(err_pipe[0], dest + total_read, sizeof(child_err) - total_read);
    if (count > 0) {
      total_read += (size_t)count;
    } else if (count == 0) {
      break;
    } else if (errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  (void)close(err_pipe[0]);

  if (total_read > 0) {
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (out_errno != NULL) {
      *out_errno = child_err != 0 ? child_err : EIO;
    }
    return -1;
  }

  if (out_errno != NULL) {
    *out_errno = 0;
  }
  return pid;
}
