const std = @import("std");
const client_mod = @import("client.zig");

/// Facade over `client.zig` for WhatsAppChannel.use_native. Pairing IQ + Noise
/// connect live here; sendText still needs a Signal session with the peer.
pub const NativeClient = client_mod.Client;

test "native client facade is Client" {
    _ = NativeClient;
    _ = &NativeClient.connect;
    _ = &NativeClient.handleIncomingFrame;
    _ = &NativeClient.encryptText;
    _ = &NativeClient.decryptIncomingMessage;
}
