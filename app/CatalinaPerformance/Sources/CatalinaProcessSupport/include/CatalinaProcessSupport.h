#ifndef CATALINA_PROCESS_SUPPORT_H
#define CATALINA_PROCESS_SUPPORT_H

#include <stdint.h>
#include <sys/types.h>

#define CP_PROCESS_NAME_MAX 64
#define CP_PROCESS_PATH_MAX 4096
#define CP_PROCESS_ARGUMENTS_MAX 16384

typedef struct {
    pid_t pid;
    pid_t parentPid;
    uid_t effectiveUid;
    int64_t startSeconds;
    int32_t startMicroseconds;
    int32_t niceValue;
    int32_t nameLength;
    int32_t pathLength;
    char name[CP_PROCESS_NAME_MAX];
    char executablePath[CP_PROCESS_PATH_MAX];
} CPProcessInfo;


typedef struct {
    uint64_t userTicks;
    uint64_t systemTicks;
    uint64_t idleTicks;
    uint64_t niceTicks;
} CPHostCPUTicks;

typedef struct {
    uint64_t physicalTotalBytes;
    uint64_t usedBytes;
    uint64_t availableBytes;
} CPHostMemoryInfo;

typedef struct {
    uint64_t totalBytes;
    uint64_t usedBytes;
    uint64_t freeBytes;
} CPSwapInfo;

typedef struct {
    pid_t pid;
    int64_t startSeconds;
    int32_t startMicroseconds;
    uint64_t cpuTimeNanoseconds;
    uint64_t residentBytes;
} CPProcessResourceInfo;

typedef struct {
    uid_t ownerUid;
    uint32_t mode;
    uint64_t size;
    int32_t isRegularFile;
    int32_t isDirectory;
    int32_t isSymbolicLink;
} CPFileInfo;

int32_t cp_process_support_available(void);
int32_t cp_read_host_cpu_ticks(CPHostCPUTicks *output);
int32_t cp_read_host_memory(CPHostMemoryInfo *output);
int32_t cp_read_swap(CPSwapInfo *output);
int32_t cp_read_process_resources(pid_t pid, CPProcessResourceInfo *output);
int32_t cp_read_process_arguments(pid_t pid, char *buffer, int32_t capacity);

int32_t cp_list_processes(CPProcessInfo *buffer, int32_t capacity);
int32_t cp_read_process(pid_t pid, CPProcessInfo *output);
int32_t cp_get_process_priority(pid_t pid, int32_t *output);
int32_t cp_set_process_priority(pid_t pid, int32_t value);
uid_t cp_console_uid(void);
int32_t cp_lstat_path(const char *path, CPFileInfo *output);
int32_t cp_open_lock(const char *path);
void cp_close_fd(int32_t fileDescriptor);
int32_t cp_last_errno(void);

#endif
