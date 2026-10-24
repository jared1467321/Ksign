#include "Rebind.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const AsignIdentityBinding *Bindings;
static size_t BindingCount;
static char *Scope;
static char *CanonicalScope;
static size_t ScopeLength;
static const struct mach_header *SelfImage;

static void replacePointer(void **slot, void *replacement) {
    vm_address_t address = (vm_address_t)slot;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &address, &regionSize, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS) return;
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    vm_size_t pageSize = (vm_size_t)getpagesize();
    vm_address_t page = (vm_address_t)slot & ~(pageSize - 1);
    if (vm_protect(mach_task_self(), page, pageSize, FALSE,
                   info.protection | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    // Keep read-only data read-only after changing just the matched pointer.
    vm_protect(mach_task_self(), page, pageSize, FALSE, info.protection);
}

static void rebindImage(const struct mach_header *header, intptr_t slide) {
    if (header == SelfImage || header->magic != MH_MAGIC_64) return;
    Dl_info image;
    if (!dladdr(header, &image) || !image.dli_fname) return;
    int inScope = !strncmp(image.dli_fname, Scope, ScopeLength) && image.dli_fname[ScopeLength] == '/';
    if (!inScope && CanonicalScope) {
        size_t length = strlen(CanonicalScope);
        inScope = !strncmp(image.dli_fname, CanonicalScope, length) && image.dli_fname[length] == '/';
    }
    if (!inScope) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->sizeofcmds > 16 * 1024 * 1024) return;
    const uint8_t *start = (const uint8_t *)(mh + 1), *end = start + mh->sizeofcmds;
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *indirect = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const uint8_t *cursor = start;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return;
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > (size_t)(end - cursor)) return;
        if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (!strncmp(seg->segname, SEG_LINKEDIT, 16)) linkedit = seg;
        } else if (cmd->cmd == LC_SYMTAB && cmd->cmdsize >= sizeof(*symbols)) symbols = (const void *)cmd;
        else if (cmd->cmd == LC_DYSYMTAB && cmd->cmdsize >= sizeof(*indirect)) indirect = (const void *)cmd;
        cursor += cmd->cmdsize;
    }
    const struct nlist_64 *names = NULL;
    const char *strings = NULL;
    const uint32_t *indices = NULL;
    if (linkedit && symbols && indirect) {
        uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
        names = (const void *)(base + symbols->symoff);
        strings = (const void *)(base + symbols->stroff);
        indices = (const void *)(base + indirect->indirectsymoff);
    }
    cursor = start;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        cursor += cmd->cmdsize;
        if (cmd->cmd != LC_SEGMENT_64 || cmd->cmdsize < sizeof(struct segment_command_64)) continue;
        const struct segment_command_64 *seg = (const void *)cmd;
        // Authenticated slots require their original signing schema. Do not
        // write an unauthenticated pointer into an arm64e authenticated GOT.
        if (!strncmp(seg->segname, "__AUTH", 6)) continue;
        if (seg->nsects > (cmd->cmdsize - sizeof(*seg)) / sizeof(struct section_64)) continue;
        const struct section_64 *sections = (const void *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; ++j) {
            const struct section_64 *section = &sections[j];
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (!strncmp(section->sectname, "__auth", 6) || section->addr < seg->vmaddr ||
                section->addr - seg->vmaddr > seg->vmsize ||
                section->size > seg->vmsize - (section->addr - seg->vmaddr)) continue;
            void **slots = (void **)((uintptr_t)slide + section->addr);
            for (uint64_t k = 0; k < section->size / sizeof(void *); ++k) {
                const char *name = NULL;
                uint64_t n = (uint64_t)section->reserved1 + k;
                if (indices && n < indirect->nindirectsyms) {
                    uint32_t index = indices[n];
                    if (index < symbols->nsyms) {
                        uint32_t offset = names[index].n_un.n_strx;
                        if (offset < symbols->strsize && strings[offset] == '_' &&
                            memchr(strings + offset, 0, symbols->strsize - offset)) name = strings + offset + 1;
                    }
                }
                // Resolved-address matching also handles ordinary chained GOT
                // imports when there is no legacy indirect-symbol entry.
                void *current = __atomic_load_n(&slots[k], __ATOMIC_ACQUIRE);
                for (size_t b = 0; b < BindingCount; ++b) {
                    const AsignIdentityBinding *binding = &Bindings[b];
                    if ((name && !strcmp(name, binding->name)) || current == binding->original) {
                        if (current != binding->replacement) replacePointer(&slots[k], binding->replacement);
                        break;
                    }
                }
            }
        }
    }
}

void AsignIdentityRebind(const AsignIdentityBinding *bindings, size_t count, const char *scope) {
    if (!scope || !*scope || Scope) return;
    Scope = strdup(scope);
    if (!Scope) return;
    CanonicalScope = realpath(scope, NULL);
    ScopeLength = strlen(Scope);
    Bindings = bindings;
    BindingCount = count;
    Dl_info self;
    if (!dladdr((const void *)&AsignIdentityRebind, &self)) return;
    SelfImage = self.dli_fbase;
    // Includes already loaded images and frameworks/plugins loaded later.
    _dyld_register_func_for_add_image(rebindImage);
}
