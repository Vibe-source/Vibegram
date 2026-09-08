#ifndef VibePacketBridgingHeader_h
#define VibePacketBridgingHeader_h

#include <stdint.h>

void phantom_set_log_callback(void (*cb)(const char *));
char *phantom_copy_stats_json(void);
char *phantom_copy_mesh_stats_json(void);
char *phantom_run_diagnostic(const char *trojan_uri);
void phantom_free_string(char *value);
void phantom_stop_client(void);
void phantom_stop_layered_carrier(void);
int32_t phantom_start_mesh(const char *config_json, uint16_t listen_port);
int32_t phantom_import_mesh_peers(const char *peers_json);

/// Packet native start with the plain server/secret path (no fronting, no overrides).
int32_t phantom_start(const char *server_url,
                      const char *secret,
                      uint16_t listen_port);

/// Packet native start (CDN / WebSocket / QUIC / stealth / obfs / meek / REALITY).
/// Returns the bound local SOCKS5 port, or a negative error code.
int32_t phantom_start_full(const char *server_url,
                           const char *secret,
                           uint16_t listen_port,
                           const char *cdn_edge,
                           const char *host_override,
                           const char *sni_override,
                           int32_t transport_mode,
                           int32_t fragment_enabled,
                           uint32_t fragment_size,
                           int32_t tls_profile,
                           const char *obfs_key,
                           const char *upstream_proxy);

/// DirectSock carrier start from a trojan:// or vless:// URI.
int32_t phantom_start_layered_carrier_full(const char *trojan_uri,
                                           uint16_t listen_port,
                                           int32_t fragment_enabled,
                                           uint32_t fragment_size);

#endif /* VibePacketBridgingHeader_h */
