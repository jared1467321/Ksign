#include <CoreFoundation/CoreFoundation.h>
CFStringRef ProbeOriginalIdentity(void) {
    return CFBundleGetIdentifier(CFBundleGetMainBundle());
}
