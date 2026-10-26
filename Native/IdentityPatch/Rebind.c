#include "Rebind.h"
#include "PatchOptions.h"
#include "RebindSupport.h"
#include <dispatch/dispatch.h>
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

static const void *linkeditData(const struct segment_command_64 *segment, intptr_t slide,
                                uint64_t offset, uint64_t size) {
    if (!AsignRangeWithin(offset, size, segment->fileoff, segment->filesize) ||
        !AsignRangeWithin(offset, size, segment->fileoff, segment->vmsize)) return NULL;
    uintptr_t mapped = (uintptr_t)slide + segment->vmaddr;
    uint64_t relative = offset - segment->fileoff;
    if (relative > UINTPTR_MAX - mapped || size > UINTPTR_MAX - (mapped + relative)) return NULL;
    return (const void *)(mapped + relative);
}

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
    if (!inScope) {
        int includesSystem = 0;
        for (size_t b = 0; b < BindingCount; ++b) includesSystem |= Bindings[b].includeSystemImages;
        if (!includesSystem) return;
    }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->sizeofcmds > 16 * 1024 * 1024) return;
    const uint8_t *start = (const uint8_t *)(mh + 1), *end = start + mh->sizeofcmds;
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *indirect = NULL;
    const struct segment_command_64 *linkedit = NULL;
    uintptr_t lazyStubs = 0;
    uint64_t lazyStubSize = 0;
    const uint8_t *cursor = start;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return;
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > (size_t)(end - cursor)) return;
        if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (!strncmp(seg->segname, SEG_LINKEDIT, 16)) linkedit = seg;
            if ((seg->initprot & VM_PROT_EXECUTE) &&
                seg->nsects <= (cmd->cmdsize - sizeof(*seg)) / sizeof(struct section_64)) {
                const struct section_64 *sections = (const void *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j) {
                    const struct section_64 *section = &sections[j];
                    if (!strncmp(section->sectname, "__stub_helper", 16) &&
                        AsignRangeWithin(section->addr, section->size, seg->vmaddr, seg->vmsize)) {
                        lazyStubs = (uintptr_t)slide + section->addr;
                        lazyStubSize = section->size;
                    }
                }
            }
        } else if (cmd->cmd == LC_SYMTAB && cmd->cmdsize >= sizeof(*symbols)) symbols = (const void *)cmd;
        else if (cmd->cmd == LC_DYSYMTAB && cmd->cmdsize >= sizeof(*indirect)) indirect = (const void *)cmd;
        cursor += cmd->cmdsize;
    }
    const struct nlist_64 *names = NULL;
    const char *strings = NULL;
    const uint32_t *indices = NULL;
    if (linkedit && symbols && indirect) {
        names = linkeditData(linkedit, slide, symbols->symoff, (uint64_t)symbols->nsyms * sizeof(*names));
        strings = linkeditData(linkedit, slide, symbols->stroff, symbols->strsize);
        indices = linkeditData(linkedit, slide, indirect->indirectsymoff, (uint64_t)indirect->nindirectsyms * sizeof(*indices));
        // A stripped or inconsistent symbol table must not crash the app just
        // because the patch inspected it. Resolved-address matching still works.
        if (!names || !strings) indices = NULL;
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
            uintptr_t slotsAddress = (uintptr_t)slide + section->addr;
            if (slotsAddress % sizeof(void *) || section->size % sizeof(void *) ||
                section->size > UINTPTR_MAX - slotsAddress) continue;
            void **slots = (void **)slotsAddress;
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
                    if (!inScope && !binding->includeSystemImages) continue;
                    int unresolvedLazy = type == S_LAZY_SYMBOL_POINTERS && lazyStubs &&
                        AsignRangeWithin((uintptr_t)current, 1, lazyStubs, lazyStubSize);
                    if (AsignImportNeedsReplacement(name, binding->name, current, binding->original,
                                                    binding->replacement, unresolvedLazy)) {
                        replacePointer(&slots[k], binding->replacement);
                        break;
                    }
                }
            }
        }
    }
}

static void registerImages(void *unused) {
    (void)unused;
    _dyld_register_func_for_add_image(rebindImage);
}

void AsignIdentityRebind(const AsignIdentityBinding *bindings, size_t count, const char *scope) {
    if (!AsignPatchEnabled(AsignPatchImageCallbacks) || !count || !scope || !*scope || Scope) return;
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
    // Deferral is diagnostic only: it deliberately misses app-initializer
    // imports so we can distinguish startup registration from later work.
    if (ASIGN_PATCH_DEFER_IMAGE_CALLBACKS) dispatch_async_f(dispatch_get_main_queue(), NULL, registerImages);
    else registerImages(NULL);
}
