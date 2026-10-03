#include "bundle.h"

// Exercise the same native entry point as ZsignBridge, without UIKit/ObjC.
int main(int argc, char **argv)
{
    if (argc != 4)
        return 2;
    ZSignAsset asset;
    if (!asset.Init("", "", "", "", "", true, false, false))
        return 3;
    ZBundle bundle;
    bundle.SetArchiveBacking(argv[2], argv[3], {});
    return bundle.SignFolder(&asset, argv[1], "", "", "", {}, {}, true, false, false, false) ? 0 : 1;
}
