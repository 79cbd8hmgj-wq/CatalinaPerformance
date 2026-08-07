#include "CatalinaProcessSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

static int32_t cp_copy_string(char *destination, int32_t capacity, const char *source) {
    if (destination == NULL || capacity <= 0 || source == NULL) return -EINVAL;
    size_t length = strnlen(source, (size_t)capacity);
    if (length >= (size_t)capacity) return -ENAMETOOLONG;
    memcpy(destination, source, length);
    destination[length] = '\0';
    return (int32_t)length;
}

int32_t cp_get_process_priority(pid_t pid, int32_t *output) {
    if (output == NULL) return -EINVAL;
    errno = 0;
    int value = getpriority(PRIO_PROCESS, pid);
    if (value == -1 && errno != 0) return -errno;
    *output = (int32_t)value;
    return 0;
}

int32_t cp_set_process_priority(pid_t pid, int32_t value) {
    if (value < -20 || value > 20) return -EINVAL;
    if (setpriority(PRIO_PROCESS, pid, value) != 0) return -errno;
    return 0;
}

int32_t cp_lstat_path(const char *path, CPFileInfo *output) {
    if (path == NULL || output == NULL) return -EINVAL;
    struct stat value;
    if (lstat(path, &value) != 0) return -errno;
    memset(output, 0, sizeof(*output));
    output->ownerUid = value.st_uid;
    output->mode = (uint32_t)(value.st_mode & 07777);
    output->size = (uint64_t)value.st_size;
    output->isRegularFile = S_ISREG(value.st_mode) ? 1 : 0;
    output->isDirectory = S_ISDIR(value.st_mode) ? 1 : 0;
    output->isSymbolicLink = S_ISLNK(value.st_mode) ? 1 : 0;
    return 0;
}

int32_t cp_open_lock(const char *path) {
    if (path == NULL) return -EINVAL;
    int descriptor = open(path, O_CREAT | O_RDWR, 0600);
    if (descriptor < 0) return -errno;
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        int saved = errno;
        close(descriptor);
        return -saved;
    }
    return descriptor;
}

void cp_close_fd(int32_t fileDescriptor) {
    if (fileDescriptor >= 0) close(fileDescriptor);
}

int32_t cp_last_errno(void) {
    return errno;
}

#if defined(__APPLE__)

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <sys/sysctl.h>

int32_t cp_process_support_available(void) { return 1; }

int32_t cp_read_host_cpu_ticks(CPHostCPUTicks *output) {
    if (output == NULL) return -EINVAL;
    natural_t cpuCount = 0;
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t cpuInfoCount = 0;
    kern_return_t result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &cpuInfoCount);
    if (result != KERN_SUCCESS) return -EIO;

    uint64_t user = 0, system = 0, idle = 0, nice = 0;
    processor_cpu_load_info_t loads = (processor_cpu_load_info_t)cpuInfo;
    for (natural_t index = 0; index < cpuCount; index++) {
        user += loads[index].cpu_ticks[CPU_STATE_USER];
        system += loads[index].cpu_ticks[CPU_STATE_SYSTEM];
        idle += loads[index].cpu_ticks[CPU_STATE_IDLE];
        nice += loads[index].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, (vm_size_t)(cpuInfoCount * sizeof(integer_t)));

    output->userTicks = user;
    output->systemTicks = system;
    output->idleTicks = idle;
    output->niceTicks = nice;
    return 0;
}

int32_t cp_read_host_memory(CPHostMemoryInfo *output) {
    if (output == NULL) return -EINVAL;
    vm_statistics64_data_t stats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count);
    if (result != KERN_SUCCESS) return -EIO;

    vm_size_t pageSize = 0;
    result = host_page_size(mach_host_self(), &pageSize);
    if (result != KERN_SUCCESS || pageSize == 0) return -EIO;

    uint64_t physical = 0;
    size_t physicalSize = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &physicalSize, NULL, 0) != 0) return -errno;

    uint64_t freeBytes = (uint64_t)stats.free_count * (uint64_t)pageSize;
    if (freeBytes > physical) freeBytes = physical;

    uint64_t availablePages = (uint64_t)stats.free_count + (uint64_t)stats.inactive_count;
    uint64_t available = availablePages * (uint64_t)pageSize;
    if (available > physical) available = physical;

    output->physicalTotalBytes = physical;
    output->usedBytes = physical - freeBytes;
    output->availableBytes = available;
    return 0;
}

int32_t cp_read_swap(CPSwapInfo *output) {
    if (output == NULL) return -EINVAL;
    struct xsw_usage usage;
    size_t size = sizeof(usage);
    if (sysctlbyname("vm.swapusage", &usage, &size, NULL, 0) != 0) return -errno;
    output->totalBytes = (uint64_t)usage.xsu_total;
    output->usedBytes = (uint64_t)usage.xsu_used;
    output->freeBytes = (uint64_t)usage.xsu_avail;
    return 0;
}

int32_t cp_read_process_resources(pid_t pid, CPProcessResourceInfo *output) {
    if (pid <= 0 || output == NULL) return -EINVAL;
    struct rusage_info_v2 usage;
    memset(&usage, 0, sizeof(usage));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return errno == 0 ? -ESRCH : -errno;

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
    if (bytes != (int)sizeof(bsd)) return errno == 0 ? -ESRCH : -errno;

    struct proc_taskinfo task;
    memset(&task, 0, sizeof(task));
    bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, (int)sizeof(task));
    if (bytes != (int)sizeof(task)) return errno == 0 ? -ESRCH : -errno;

    output->pid = pid;
    output->startSeconds = (int64_t)bsd.pbi_start_tvsec;
    output->startMicroseconds = (int32_t)bsd.pbi_start_tvusec;
    output->cpuTimeNanoseconds = usage.ri_user_time + usage.ri_system_time;
    output->residentBytes = task.pti_resident_size;
    return 0;
}



int32_t cp_read_process_arguments(pid_t pid, char *buffer, int32_t capacity) {
    if (pid <= 0 || buffer == NULL || capacity <= 0) return -EINVAL;
    if (capacity > CP_PROCESS_ARGUMENTS_MAX) capacity = CP_PROCESS_ARGUMENTS_MAX;
    memset(buffer, 0, (size_t)capacity);

    char kernelBuffer[CP_PROCESS_ARGUMENTS_MAX];
    memset(kernelBuffer, 0, sizeof(kernelBuffer));
    size_t kernelLength = sizeof(kernelBuffer);
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    if (sysctl(mib, 3, kernelBuffer, &kernelLength, NULL, 0) != 0) {
        return errno == 0 ? -EIO : -errno;
    }
    if (kernelLength < sizeof(int)) return -EIO;

    int argc = 0;
    memcpy(&argc, kernelBuffer, sizeof(argc));
    if (argc <= 0) return -EIO;

    size_t cursor = sizeof(argc);
    const char *end = kernelBuffer + kernelLength;
    const char *executableEnd = memchr(kernelBuffer + cursor, '\0', kernelLength - cursor);
    if (executableEnd == NULL) return -EIO;
    cursor = (size_t)(executableEnd - kernelBuffer) + 1;
    while (cursor < kernelLength && kernelBuffer[cursor] == '\0') cursor++;

    int copiedArguments = 0;
    int32_t outputLength = 0;
    while (copiedArguments < argc && cursor < kernelLength) {
        const char *argumentStart = kernelBuffer + cursor;
        size_t remaining = (size_t)(end - argumentStart);
        const char *argumentEnd = memchr(argumentStart, '\0', remaining);
        if (argumentEnd == NULL) return -EIO;
        size_t argumentLength = (size_t)(argumentEnd - argumentStart);
        if (argumentLength + 1 > (size_t)(capacity - outputLength)) return -E2BIG;
        memcpy(buffer + outputLength, argumentStart, argumentLength);
        outputLength += (int32_t)argumentLength;
        buffer[outputLength++] = '\0';
        copiedArguments++;
        cursor += argumentLength + 1;
    }

    if (copiedArguments != argc) return -EIO;
    return outputLength;
}

int32_t cp_read_process(pid_t pid, CPProcessInfo *output) {
    if (pid <= 0 || output == NULL) return -EINVAL;
    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
    if (bytes != (int)sizeof(bsd)) return errno == 0 ? -ESRCH : -errno;

    char path[PROC_PIDPATHINFO_MAXSIZE];
    memset(path, 0, sizeof(path));
    int pathBytes = proc_pidpath(pid, path, (uint32_t)sizeof(path));
    if (pathBytes <= 0) return errno == 0 ? -ENOENT : -errno;

    int32_t niceValue = 0;
    int32_t priorityResult = cp_get_process_priority(pid, &niceValue);
    if (priorityResult != 0) return priorityResult;

    memset(output, 0, sizeof(*output));
    output->pid = pid;
    output->parentPid = (pid_t)bsd.pbi_ppid;
    output->effectiveUid = (uid_t)bsd.pbi_uid;
    output->startSeconds = (int64_t)bsd.pbi_start_tvsec;
    output->startMicroseconds = (int32_t)bsd.pbi_start_tvusec;
    output->niceValue = niceValue;

    int32_t nameLength = cp_copy_string(output->name, CP_PROCESS_NAME_MAX, bsd.pbi_comm);
    if (nameLength < 0) return nameLength;
    output->nameLength = nameLength;

    int32_t copiedPathLength = cp_copy_string(output->executablePath, CP_PROCESS_PATH_MAX, path);
    if (copiedPathLength < 0) return copiedPathLength;
    output->pathLength = copiedPathLength;
    return 0;
}

int32_t cp_list_processes(CPProcessInfo *buffer, int32_t capacity) {
    if (capacity < 0) return -EINVAL;
    int required = proc_listallpids(NULL, 0);
    if (required <= 0) return errno == 0 ? -EIO : -errno;
    if (buffer == NULL || capacity == 0) return required;

    pid_t *pids = (pid_t *)calloc((size_t)required, sizeof(pid_t));
    if (pids == NULL) return -ENOMEM;
    int count = proc_listallpids(pids, required * (int)sizeof(pid_t));
    if (count < 0) {
        int saved = errno;
        free(pids);
        return -saved;
    }

    int32_t written = 0;
    for (int index = 0; index < count && written < capacity; index++) {
        CPProcessInfo info;
        if (cp_read_process(pids[index], &info) == 0) buffer[written++] = info;
    }
    free(pids);
    return written;
}

uid_t cp_console_uid(void) {
    struct stat value;
    if (stat("/dev/console", &value) != 0) return (uid_t)-1;
    return value.st_uid;
}

#else

int32_t cp_process_support_available(void) { return 0; }

int32_t cp_read_host_cpu_ticks(CPHostCPUTicks *output) { (void)output; return -ENOTSUP; }
int32_t cp_read_host_memory(CPHostMemoryInfo *output) { (void)output; return -ENOTSUP; }
int32_t cp_read_swap(CPSwapInfo *output) { (void)output; return -ENOTSUP; }
int32_t cp_read_process_resources(pid_t pid, CPProcessResourceInfo *output) { (void)pid; (void)output; return -ENOTSUP; }
int32_t cp_read_process_arguments(pid_t pid, char *buffer, int32_t capacity) { (void)pid; (void)buffer; (void)capacity; return -ENOTSUP; }

int32_t cp_list_processes(CPProcessInfo *buffer, int32_t capacity) {
    (void)buffer; (void)capacity; return -ENOTSUP;
}
int32_t cp_read_process(pid_t pid, CPProcessInfo *output) {
    (void)pid; (void)output; return -ENOTSUP;
}
uid_t cp_console_uid(void) { return getuid(); }

#endif
