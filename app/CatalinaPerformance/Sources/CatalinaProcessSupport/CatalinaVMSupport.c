#include "CatalinaProcessSupport.h"

#include <errno.h>
#include <string.h>

#if defined(__APPLE__)

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/sysctl.h>

int32_t cp_read_vm_memory_info(CPVMMemoryInfo *output) {
    if (output == NULL) return -EINVAL;

    vm_statistics64_data_t stats;
    memset(&stats, 0, sizeof(stats));
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        (host_info64_t)&stats,
        &count
    );
    if (result != KERN_SUCCESS) return -EIO;

    vm_size_t pageSize = 0;
    result = host_page_size(mach_host_self(), &pageSize);
    if (result != KERN_SUCCESS || pageSize == 0) return -EIO;

    uint64_t physical = 0;
    size_t physicalSize = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &physicalSize, NULL, 0) != 0) {
        return errno == 0 ? -EIO : -errno;
    }
    if (physical == 0) return -EIO;

    memset(output, 0, sizeof(*output));
    output->physicalBytes = physical;
    output->freePages = (uint64_t)stats.free_count;
    output->inactivePages = (uint64_t)stats.inactive_count;
    output->activePages = (uint64_t)stats.active_count;
    output->wiredPages = (uint64_t)stats.wire_count;
    output->speculativePages = (uint64_t)stats.speculative_count;
    output->purgeablePages = (uint64_t)stats.purgeable_count;
    output->compressorPages = (uint64_t)stats.compressor_page_count;
    output->pagesStoredInCompressor = (uint64_t)stats.total_uncompressed_pages_in_compressor;
    output->compressions = (uint64_t)stats.compressions;
    output->decompressions = (uint64_t)stats.decompressions;
    output->pageIns = (uint64_t)stats.pageins;
    output->pageOuts = (uint64_t)stats.pageouts;
    output->swapIns = (uint64_t)stats.swapins;
    output->swapOuts = (uint64_t)stats.swapouts;
    output->pageSize = (uint64_t)pageSize;
    output->availabilityMask =
        CP_VM_INFO_FREE_PAGES |
        CP_VM_INFO_INACTIVE_PAGES |
        CP_VM_INFO_ACTIVE_PAGES |
        CP_VM_INFO_WIRED_PAGES |
        CP_VM_INFO_SPECULATIVE_PAGES |
        CP_VM_INFO_PURGEABLE_PAGES |
        CP_VM_INFO_COMPRESSOR_PAGES |
        CP_VM_INFO_COMPRESSOR_STORED_PAGES |
        CP_VM_INFO_COMPRESSIONS |
        CP_VM_INFO_DECOMPRESSIONS |
        CP_VM_INFO_PAGE_INS |
        CP_VM_INFO_PAGE_OUTS |
        CP_VM_INFO_SWAP_INS |
        CP_VM_INFO_SWAP_OUTS;
    return 0;
}

#else

int32_t cp_read_vm_memory_info(CPVMMemoryInfo *output) {
    (void)output;
    return -ENOTSUP;
}

#endif
