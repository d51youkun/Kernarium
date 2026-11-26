// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef JIT_BRIDGE_H
#define JIT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*JitBridgeReadyCb)(
    void *ctx,
    const char *service_id,
    uint16_t port,
    const char *const *txt_keys,
    const char *const *txt_vals,
    size_t txt_count);

typedef void (*JitBridgePinCb)(const char *pin, void *ctx);
typedef int32_t (*JitBridgeCancelledCb)(void *ctx);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
} JitBridgePairResult;

/// Starts a pairable host listener on `bind_addr:port` (pass 0 for ephemeral port),
/// invokes `ready_cb` with the Bonjour service ID, port, and TXT records,
/// invokes `pin_cb` with the 6-digit PIN when the device connects,
/// and writes the resulting RemotePairing plist to `out_path`.
/// Returns 0 on success.
int32_t jit_bridge_pair_host(
    const char *bind_addr,
    uint16_t port,
    const char *name,
    const char *model,
    const char *out_path,
    JitBridgeReadyCb ready_cb,
    JitBridgePinCb pin_cb,
    JitBridgeCancelledCb cancelled_cb,
    void *ctx,
    JitBridgePairResult *out);

void jit_bridge_pair_result_free(JitBridgePairResult *res);

#ifdef __cplusplus
}
#endif

#endif /* JIT_BRIDGE_H */
