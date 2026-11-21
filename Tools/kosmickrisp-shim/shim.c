// libMoltenVK.dylib stand-in that forwards to a Vulkan ICD (KosmicKrisp).
//
// Wine's win32u dlopens "libMoltenVK.dylib" (or the file CrossOver's CX_LIBVULKAN names) and resolves the
// whole Vulkan API through its exported vkGetInstanceProcAddr. Mesa drivers such as KosmicKrisp export only the loader interface
// (vk_icdGetInstanceProcAddr, vk_icdNegotiateLoaderICDInterfaceVersion), so they cannot be dropped in.
// This shim exports the plain entry points and forwards to the ICD in the same folder, with no Vulkan
// loader in between. Only the game itself goes to KosmicKrisp: a process whose .exe lives under
// steamapps\common\ (or matches GAMEPORT_KOSMICKRISP_MATCH). Everything else (Steam, its web helper, explorer,
// Wine's services) gets the engine's real MoltenVK: Steam's web UI got no device on KosmicKrisp.
// Build: Tools/kosmickrisp-shim/build.sh
#include <crt_externs.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*PFN_void)(void);
typedef void *VkInstance;
typedef void *VkDevice;
typedef int32_t VkResult;
typedef PFN_void (*PFN_gipa)(VkInstance, const char *);
typedef PFN_void (*PFN_gdpa)(VkDevice, const char *);
typedef VkResult (*PFN_negotiate)(uint32_t *);

static PFN_gipa icd_gipa;
static PFN_gdpa icd_gdpa;
static int trace;   // on KosmicKrisp, or with GAMEPORT_VK_TRACE=1
PFN_void vkGetInstanceProcAddr(VkInstance instance, const char *name);
PFN_void vkGetDeviceProcAddr(VkDevice device, const char *name);
static pthread_once_t once = PTHREAD_ONCE_INIT;

/// Wine rewrites a process's argv to its Windows command line, so argv[0] names the .exe.
static const char *process_exe(void) {
    char **argv = *_NSGetArgv();
    return (argv && argv[0]) ? argv[0] : "";
}

static int is_game_process(const char *exe) {
    const char *match = getenv("GAMEPORT_KOSMICKRISP_MATCH");
    return strcasestr(exe, (match && *match) ? match : "\\steamapps\\common\\") != NULL;
}

static void load_icd(void) {
    Dl_info info;
    char dir[4096] = ".", path[4096];
    if (dladdr((void *)load_icd, &info) && info.dli_fname) {
        const char *slash = strrchr(info.dli_fname, '/');
        if (slash && (size_t)(slash - info.dli_fname) < sizeof(dir))
            snprintf(dir, sizeof(dir), "%.*s", (int)(slash - info.dli_fname), info.dli_fname);
    }
    const char *exe = process_exe();
    const char *trace_env = getenv("GAMEPORT_VK_TRACE");
    trace = trace_env && (!strcmp(trace_env, "1") || !strcmp(trace_env, "2"));
    if (!is_game_process(exe)) {
        // If a profile finds this shim through DYLD_LIBRARY_PATH, dyld applies that to the leaf name of every
        // load, full paths included, so "…/frameworks/libMoltenVK.dylib" would give back this shim. build.sh
        // puts a link with a different leaf name next to the shim. (try.sh uses CX_LIBVULKAN instead.)
        snprintf(path, sizeof(path), "%s/libMoltenVK-engine.dylib", dir);
        void *mvk = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!mvk) { fprintf(stderr, "kosmickrisp-shim: %s\n", dlerror()); return; }
        icd_gipa = (PFN_gipa)dlsym(mvk, "vkGetInstanceProcAddr");
        icd_gdpa = (PFN_gdpa)dlsym(mvk, "vkGetDeviceProcAddr");
        // Never forward to ourselves (that recursed until Steam's web helper hung).
        if (icd_gipa == (PFN_gipa)vkGetInstanceProcAddr) icd_gipa = NULL;
        fprintf(stderr, "kosmickrisp-shim: %s on MoltenVK%s\n", exe, icd_gipa ? "" : " (not found)");
        return;
    }
    snprintf(path, sizeof(path), "%s/libvulkan_kosmickrisp.dylib", dir);
    void *icd = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!icd) { fprintf(stderr, "kosmickrisp-shim: %s\n", dlerror()); return; }
    PFN_negotiate negotiate = (PFN_negotiate)dlsym(icd, "vk_icdNegotiateLoaderICDInterfaceVersion");
    if (negotiate) {
        uint32_t version = 7;
        negotiate(&version);
    }
    icd_gipa = (PFN_gipa)dlsym(icd, "vk_icdGetInstanceProcAddr");
    trace = 1;
    fprintf(stderr, "kosmickrisp-shim: %s on KosmicKrisp %s\n", exe, path);
}

// Diagnostics on KosmicKrisp (or with GAMEPORT_VK_TRACE=1 on MoltenVK): the instance extensions, and what instance creation,
// device enumeration and device creation return, and what the GPU offers, so a game that gives up (DXVK throwing "no adapter") shows why.
typedef void *VkPhysicalDevice;
typedef VkResult (*PFN_create_instance)(const void *, const void *, VkInstance *);
typedef VkResult (*PFN_enum_devices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (*PFN_get_properties)(VkPhysicalDevice, void *);
typedef VkResult (*PFN_enum_extensions)(VkPhysicalDevice, const char *, uint32_t *, void *);
typedef VkResult (*PFN_create_device)(VkPhysicalDevice, const void *, const void *, VkDevice *);
static PFN_create_instance real_create_instance;
static PFN_enum_devices real_enum_devices;
static PFN_create_device real_create_device;
static VkInstance last_instance;

typedef VkResult (*PFN_enum_instance_extensions)(const char *, uint32_t *, void *);
static PFN_enum_instance_extensions real_enum_instance_extensions;

// Wine turns down vkCreateInstance itself when the driver lacks an instance extension it maps the
// game's request to (VK_KHR_win32_surface → VK_EXT_metal_surface), so the driver's list matters.
static VkResult logged_enum_instance_extensions(const char *layer, uint32_t *count, void *props) {
    static int described;
    VkResult r = real_enum_instance_extensions(layer, count, props);
    if (props && r >= 0 && count && !described) {
        described = 1;
        struct { char name[256]; uint32_t spec; } *ext = props;
        fprintf(stderr, "kosmickrisp-shim: %u instance extensions:", *count);
        for (uint32_t i = 0; i < *count; i++) fprintf(stderr, " %s", ext[i].name);
        fprintf(stderr, "\n");
    }
    return r;
}

typedef VkResult (*PFN_enum_version)(uint32_t *);
static PFN_enum_version real_enum_version;

static VkResult logged_enum_version(uint32_t *version) {
    VkResult r = real_enum_version(version);
    fprintf(stderr, "kosmickrisp-shim: vkEnumerateInstanceVersion = %d, %u.%u.%u\n", r,
            version ? *version >> 22 : 0, version ? (*version >> 12) & 0x3ff : 0, version ? *version & 0xfff : 0);
    return r;
}

static VkResult logged_create_instance(const void *info, const void *alloc, VkInstance *instance) {
    VkResult r = real_create_instance(info, alloc, instance);
    fprintf(stderr, "kosmickrisp-shim: vkCreateInstance = %d\n", r);
    if (r == 0) last_instance = *instance;
    return r;
}

static void describe_device(VkPhysicalDevice device) {
    // VkPhysicalDeviceProperties: apiVersion, driverVersion, vendorID, deviceID, deviceType, deviceName[256], …
    struct { uint32_t api, driver, vendor, id, type; char name[256]; char rest[4096]; } props = {0};
    PFN_get_properties get = (PFN_get_properties)icd_gipa(last_instance, "vkGetPhysicalDeviceProperties");
    if (get) get(device, &props);
    fprintf(stderr, "kosmickrisp-shim: device \"%s\" Vulkan %u.%u.%u, type %u\n", props.name,
            props.api >> 22, (props.api >> 12) & 0x3ff, props.api & 0xfff, props.type);
    PFN_enum_extensions enum_ext = (PFN_enum_extensions)icd_gipa(last_instance, "vkEnumerateDeviceExtensionProperties");
    uint32_t n = 0;
    if (!enum_ext || enum_ext(device, NULL, &n, NULL) != 0 || !n) return;
    struct { char name[256]; uint32_t spec; } *ext = calloc(n, sizeof(*ext));
    if (ext && enum_ext(device, NULL, &n, ext) >= 0) {
        fprintf(stderr, "kosmickrisp-shim: %u device extensions:", n);
        for (uint32_t i = 0; i < n; i++) fprintf(stderr, " %s", ext[i].name);
        fprintf(stderr, "\n");
    }
    free(ext);
}

static VkResult logged_enum_devices(VkInstance instance, uint32_t *count, VkPhysicalDevice *devices) {
    static int described;
    VkResult r = real_enum_devices(instance, count, devices);
    fprintf(stderr, "kosmickrisp-shim: vkEnumeratePhysicalDevices = %d, %u device(s)\n", r, count ? *count : 0);
    if (devices && r >= 0 && count && *count && !described) {
        described = 1;
        last_instance = instance;
        describe_device(devices[0]);
    }
    return r;
}

// VK_ERROR_FEATURE_NOT_PRESENT names no feature, so on that error (or always with GAMEPORT_VK_TRACE=2) the shim
// compares every feature bit the device request asks for with what the driver reports. Feature structures
// are sType, pNext, then VkBool32 fields; the table gives the field count of the ones DXVK and Wine use.
typedef struct { int32_t sType; const void *pNext; } VkBase;
typedef void (*PFN_get_features2)(VkPhysicalDevice, void *);
static const char *const core_features[] = {
    "robustBufferAccess", "fullDrawIndexUint32", "imageCubeArray", "independentBlend", "geometryShader",
    "tessellationShader", "sampleRateShading", "dualSrcBlend", "logicOp", "multiDrawIndirect",
    "drawIndirectFirstInstance", "depthClamp", "depthBiasClamp", "fillModeNonSolid", "depthBounds", "wideLines",
    "largePoints", "alphaToOne", "multiViewport", "samplerAnisotropy", "textureCompressionETC2",
    "textureCompressionASTC_LDR", "textureCompressionBC", "occlusionQueryPrecise", "pipelineStatisticsQuery",
    "vertexPipelineStoresAndAtomics", "fragmentStoresAndAtomics", "shaderTessellationAndGeometryPointSize",
    "shaderImageGatherExtended", "shaderStorageImageExtendedFormats", "shaderStorageImageMultisample",
    "shaderStorageImageReadWithoutFormat", "shaderStorageImageWriteWithoutFormat",
    "shaderUniformBufferArrayDynamicIndexing", "shaderSampledImageArrayDynamicIndexing",
    "shaderStorageBufferArrayDynamicIndexing", "shaderStorageImageArrayDynamicIndexing", "shaderClipDistance",
    "shaderCullDistance", "shaderFloat64", "shaderInt64", "shaderInt16", "shaderResourceResidency",
    "shaderResourceMinLod", "sparseBinding", "sparseResidencyBuffer", "sparseResidencyImage2D",
    "sparseResidencyImage3D", "sparseResidency2Samples", "sparseResidency4Samples", "sparseResidency8Samples",
    "sparseResidency16Samples", "sparseResidencyAliased", "variableMultisampleRate", "inheritedQueries",
};
static const struct { int32_t sType; int fields; const char *name; } feature_structs[] = {
    {1000059000, 55, "Features2"}, {49, 12, "Vulkan11"}, {51, 47, "Vulkan12"}, {53, 15, "Vulkan13"},
    {1000340000, 2, "4444Formats"}, {1000287002, 2, "CustomBorderColor"}, {1000102000, 1, "DepthClipEnable"},
    {1000267000, 1, "ExtendedDynamicState"}, {1000261000, 1, "HostQueryReset"}, {1000238000, 1, "MemoryPriority"},
    {1000422000, 1, "NonSeamlessCubeMap"}, {1000286000, 3, "Robustness2"}, {1000276000, 1, "DemoteToHelper"},
    {1000028000, 2, "TransformFeedback"}, {1000190002, 2, "VertexAttributeDivisor"},
    {1000257000, 3, "BufferDeviceAddress"}, {1000207000, 1, "TimelineSemaphore"},
    {1000063000, 1, "ShaderDrawParameters"},
};

// Requested bits the driver does not report can be switched off for a retry (see logged_create_device); the
// request belongs to the caller, so every change is undone right after the call.
static struct { uint32_t *where; uint32_t value; } saved[256];
static int nsaved;

static int check_bools(const char *what, uint32_t *want, const uint32_t *have, int n, const char *const *names, int drop) {
    int missing = 0;
    for (int i = 0; i < n; i++) {
        if (!want[i] || have[i]) continue;
        missing++;
        if (names) fprintf(stderr, "kosmickrisp-shim: requested but not supported: %s.%s%s\n", what, names[i], drop ? " (dropped)" : "");
        else fprintf(stderr, "kosmickrisp-shim: requested but not supported: %s field %d%s\n", what, i, drop ? " (dropped)" : "");
        if (drop && nsaved < 256) { saved[nsaved].where = &want[i]; saved[nsaved++].value = want[i]; want[i] = 0; }
    }
    return missing;
}

static void restore_features(void) {
    while (nsaved > 0) { nsaved--; *saved[nsaved].where = saved[nsaved].value; }
}

/// Returns how many requested feature bits the driver does not report; with `drop`, also switches them off.
static int check_features(VkPhysicalDevice device, const void *info, int drop) {
    PFN_get_features2 get = (PFN_get_features2)icd_gipa(last_instance, "vkGetPhysicalDeviceFeatures2");
    if (!get) get = (PFN_get_features2)icd_gipa(last_instance, "vkGetPhysicalDeviceFeatures2KHR");
    // A Vulkan 1.0 instance without VK_KHR_get_physical_device_properties2 can only check the core features.
    PFN_get_features2 get_core = get ? NULL : (PFN_get_features2)icd_gipa(last_instance, "vkGetPhysicalDeviceFeatures");
    if (!get && !get_core) { fprintf(stderr, "kosmickrisp-shim: no vkGetPhysicalDeviceFeatures\n"); return 0; }
    // VkDeviceCreateInfo: pNext at 8, pEnabledFeatures at 64.
    VkBase *chain = *(VkBase *const *)((const char *)info + 8);
    uint32_t *core = *(uint32_t *const *)((const char *)info + 64);
    struct { VkBase base; uint32_t bools[64]; } query[24];
    memset(query, 0, sizeof(query));
    query[0].base.sType = 1000059000;       // VkPhysicalDeviceFeatures2 for the core features
    int n = 1, missing = 0;
    char seen[512] = "";
    const size_t known = sizeof(feature_structs) / sizeof(feature_structs[0]);
    for (VkBase *b = chain; b; b = (VkBase *)b->pNext) {
        size_t k = 0;
        while (k < known && feature_structs[k].sType != b->sType) k++;
        if (k == known) { snprintf(seen + strlen(seen), sizeof(seen) - strlen(seen), " %d", b->sType); continue; }
        if (b->sType == 1000059000 || n >= 24) continue;
        query[n].base.sType = b->sType;
        query[n - 1].base.pNext = &query[n];
        n++;
    }
    if (get) get(device, &query[0]);
    else get_core(device, query[0].bools);
    if (core) missing += check_bools("core", core, query[0].bools, 55, core_features, drop);
    for (VkBase *b = chain; b; b = (VkBase *)b->pNext) {
        for (size_t k = 0; k < known; k++) {
            if (feature_structs[k].sType != b->sType) continue;
            uint32_t *want = (uint32_t *)(b + 1);
            if (b->sType == 1000059000) { missing += check_bools("core", want, query[0].bools, 55, core_features, drop); break; }
            for (int q = 1; q < n; q++)
                if (query[q].base.sType == b->sType)
                    missing += check_bools(feature_structs[k].name, want, query[q].bools, feature_structs[k].fields, NULL, drop);
            break;
        }
    }
    fprintf(stderr, "kosmickrisp-shim: features checked; other structures in the request:%s\n", seen[0] ? seen : " none");
    return missing;
}

// DXVK's D3D9 asks for fillModeNonSolid (wireframe) whether or not the driver has it, and KosmicKrisp does not,
// so the device was refused. On VK_ERROR_FEATURE_NOT_PRESENT the shim retries once with the features the
// driver does not report switched off, and logs each one (GAMEPORT_VK_KEEP_FEATURES=1 turns this off). A game
// that then uses such a feature gets undefined results for that draw, which beats having no device at all.
static VkResult logged_create_device(VkPhysicalDevice device, const void *info, const void *alloc, VkDevice *out) {
    VkResult r = real_create_device(device, info, alloc, out);
    fprintf(stderr, "kosmickrisp-shim: vkCreateDevice = %d\n", r);
    const char *t = getenv("GAMEPORT_VK_TRACE"), *keep = getenv("GAMEPORT_VK_KEEP_FEATURES");
    int may_drop = !(keep && !strcmp(keep, "1"));
    if (r == -8) {
        if (check_features(device, info, may_drop) && may_drop) {
            r = real_create_device(device, info, alloc, out);
            fprintf(stderr, "kosmickrisp-shim: vkCreateDevice without them = %d\n", r);
        }
        restore_features();
    } else if (t && !strcmp(t, "2")) {
        check_features(device, info, 0);
    }
    return r;
}

__attribute__((visibility("default")))
PFN_void vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    pthread_once(&once, load_icd);
    if (!icd_gipa || !name) return NULL;
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_void)vkGetInstanceProcAddr;
    if (instance) last_instance = instance;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_void)vkGetDeviceProcAddr;
    PFN_void f = icd_gipa(instance, name);
    // Drivers return NULL for functions of extensions an instance did not enable; only missing global
    // functions (the ones Wine needs before any instance exists) are worth a line.
    if (trace && !f && !instance) fprintf(stderr, "kosmickrisp-shim: no global %s\n", name);
    if (!trace || !f) return f;
    if (!strcmp(name, "vkEnumerateInstanceVersion")) { real_enum_version = (PFN_enum_version)f; return (PFN_void)logged_enum_version; }
    if (!strcmp(name, "vkEnumerateInstanceExtensionProperties")) {
        real_enum_instance_extensions = (PFN_enum_instance_extensions)f;
        return (PFN_void)logged_enum_instance_extensions;
    }
    if (!strcmp(name, "vkCreateInstance")) { real_create_instance = (PFN_create_instance)f; return (PFN_void)logged_create_instance; }
    if (!strcmp(name, "vkEnumeratePhysicalDevices")) { real_enum_devices = (PFN_enum_devices)f; return (PFN_void)logged_enum_devices; }
    if (!strcmp(name, "vkCreateDevice")) { real_create_device = (PFN_create_device)f; return (PFN_void)logged_create_device; }
    return f;
}

// winemac dlsyms vkCreateMetalSurfaceEXT from the library and only offers games VK_KHR_win32_surface
// on top of VK_EXT_metal_surface when it finds it; otherwise it needs MoltenVK's own VK_MVK_macos_surface,
// which KosmicKrisp lacks, and Wine refused DXVK's instance. The real MoltenVK exports it too.
typedef VkResult (*PFN_create_metal_surface)(VkInstance, const void *, const void *, void *);
__attribute__((visibility("default")))
VkResult vkCreateMetalSurfaceEXT(VkInstance instance, const void *info, const void *alloc, void *surface) {
    pthread_once(&once, load_icd);
    PFN_create_metal_surface f = icd_gipa ? (PFN_create_metal_surface)icd_gipa(instance, "vkCreateMetalSurfaceEXT") : NULL;
    return f ? f(instance, info, alloc, surface) : -7; // VK_ERROR_EXTENSION_NOT_PRESENT
}

// Wine dlsyms vkGetDeviceProcAddr from the library itself. A driver need not answer
// vkGetInstanceProcAddr(NULL, "vkGetDeviceProcAddr") (MoltenVK does not, and Wine then got no device
// functions: winevulkan's loader.c:665 assert), so it is taken from the library (MoltenVK) or from the
// first real instance Wine passes in (KosmicKrisp).
__attribute__((visibility("default")))
PFN_void vkGetDeviceProcAddr(VkDevice device, const char *name) {
    pthread_once(&once, load_icd);
    if (!icd_gdpa && last_instance) icd_gdpa = (PFN_gdpa)icd_gipa(last_instance, "vkGetDeviceProcAddr");
    if (!icd_gdpa) {
        if (trace) fprintf(stderr, "kosmickrisp-shim: vkGetDeviceProcAddr(%s) with no instance yet\n", name ? name : "");
        return NULL;
    }
    if (name && !strcmp(name, "vkGetDeviceProcAddr")) return (PFN_void)vkGetDeviceProcAddr;
    return icd_gdpa(device, name);
}
