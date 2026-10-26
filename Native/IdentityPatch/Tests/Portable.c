#include "../TypeEncoding.h"
#include "../RebindSupport.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(AsignTypeMatches("@", "@"));
    assert(AsignTypeMatches("r@\"NSString\"", "@"));
    assert(AsignTypeMatches("@\"Class<Protocol>\"", "@"));
    assert(AsignTypeMatches("n@?", "@?"));
    assert(AsignTypeMatches("rq", "q"));
    assert(!AsignTypeMatches("@?", "@"));
    assert(!AsignTypeMatches("@", "@?"));
    assert(!AsignTypeMatches("q", "@"));
    assert(!AsignTypeMatches("i", "q"));
    assert(!AsignTypeMatches("Q", "q"));
    assert(!AsignTypeMatches("^@", "@"));
    assert(!AsignTypeMatches("{Value=qq}", "@"));
    assert(!AsignTypeMatches("@\"NSString", "@"));
    assert(!AsignTypeMatches("@\"NSString\"q", "@"));
    assert(!AsignTypeMatches(NULL, "@"));
    assert(!AsignTypeMatches("", ""));

    int api, hook, other;
    assert(AsignImportNeedsReplacement("api", "api", &api, &api, &hook, 0));
    assert(AsignImportNeedsReplacement(NULL, "api", &api, &api, &hook, 0));
    // Existing hooks, weak imports and symbol aliases retain their meaning.
    assert(!AsignImportNeedsReplacement("api", "api", &other, &api, &hook, 0));
    assert(!AsignImportNeedsReplacement("api", "api", &hook, &api, &hook, 0));
    assert(!AsignImportNeedsReplacement("alias", "api", &api, &api, &hook, 0));
    assert(!AsignImportNeedsReplacement("api", "api", NULL, &api, &hook, 0));
    assert(!AsignImportNeedsReplacement(NULL, "api", NULL, NULL, &hook, 0));
    // An identified unresolved lazy import still gets repaired before use.
    assert(AsignImportNeedsReplacement("api", "api", &other, &api, &hook, 1));
    assert(!AsignImportNeedsReplacement("alias", "api", &other, &api, &hook, 1));
    assert(!AsignImportNeedsReplacement(NULL, "api", &other, &api, &hook, 1));

    assert(AsignRangeWithin(100, 16, 100, 16));
    assert(AsignRangeWithin(116, 0, 100, 16));
    assert(!AsignRangeWithin(99, 1, 100, 16));
    assert(!AsignRangeWithin(116, 1, 100, 16));
    assert(!AsignRangeWithin(101, 16, 100, 16));
    assert(!AsignRangeWithin(UINT64_MAX, 2, 100, 16));
    assert(!AsignRangeWithin(100, UINT64_MAX, 100, 16));
    assert(AsignRangeWithin(UINT64_MAX - 1, 1, UINT64_MAX - 16, 16));
    puts("ABI and import preservation checks passed");
    return 0;
}
