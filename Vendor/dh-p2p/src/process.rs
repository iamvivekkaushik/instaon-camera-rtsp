use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UdpSocket,
    sync::{mpsc, oneshot, Mutex as AsyncMutex},
};

use crate::ptcp::{PTCPBody, PTCPEvent, PTCPPayload, PTCPSession, PTCP};

/// Serialize every PTCP write (build counters + UDP send).
///
/// Reader ACKs and writer Data/Heartbeat/Bind share one session. If packet
/// construction and UDP send are split across tasks without a wire lock,
/// two packets can leave in reverse order of their `sent`/`recv`/`lmid`
/// values. After PLAY that reorder freezes the agent flow-control window:
/// one ~1.2KB interleaved RTP payload arrives, then silence.
async fn ptcp_send(
    session: &Arc<Mutex<PTCPSession>>,
    wire: &Arc<AsyncMutex<()>>,
    socket: &Arc<UdpSocket>,
    body: PTCPBody,
) {
    let _wire = wire.lock().await;
    let p = session.lock().unwrap().send(body);
    socket.ptcp_request(p).await;
}

/**
 * Read data from the channel and write it back to the client
 */
pub async fn process_writer(
    mut writer: tokio::net::tcp::OwnedWriteHalf,
    mut rx: mpsc::UnboundedReceiver<Vec<u8>>,
) {
    loop {
        let Some(data) = rx.recv().await else {
            break;
        };
        if writer.write_all(&data).await.is_err() {
            println!("Writer: Socket closed by peer.");
            break;
        }
    }
}

/**
 * Read data from the client and send it to the channel
 */
pub async fn process_reader(
    mut reader: tokio::net::tcp::OwnedReadHalf,
    realm_id: u32,
    dh_tx: mpsc::Sender<PTCPEvent>,
    channels: Arc<Mutex<HashMap<u32, mpsc::UnboundedSender<Vec<u8>>>>>,
) {
    // Large enough for full RTSP requests and occasional client RTCP.
    let mut buf = [0u8; 65536];

    loop {
        let n = match reader.read(&mut buf).await {
            Ok(n) => {
                if n == 0 {
                    println!("Reader: Socket closed by peer.");
                    break;
                }
                n
            }
            Err(e) => {
                println!("Reader: {}", e);
                break;
            }
        };

        if dh_tx
            .send(PTCPEvent::Data(realm_id, buf[0..n].to_vec()))
            .await
            .is_err()
        {
            break;
        }
    }

    // Drop local TCP→PTCP fan-in and tell the device the realm is gone.
    channels.lock().unwrap().remove(&realm_id);
    let _ = dh_tx.send(PTCPEvent::Disconnect(realm_id)).await;
}

/**
* Read data from client and send it to devices
*/
pub async fn dh_writer(
    session: Arc<Mutex<PTCPSession>>,
    wire: Arc<AsyncMutex<()>>,
    socket: Arc<UdpSocket>,
    mut dh_rx: mpsc::Receiver<PTCPEvent>,
    remote_port: u32,
) {
    loop {
        let Some(ev) = dh_rx.recv().await else {
            break;
        };

        match ev {
            PTCPEvent::Heartbeat => {
                ptcp_send(&session, &wire, &socket, PTCPBody::Heartbeat).await;
            }
            PTCPEvent::Connect(realm) => {
                ptcp_send(
                    &session,
                    &wire,
                    &socket,
                    PTCPBody::Bind(realm, remote_port),
                )
                .await;
            }
            PTCPEvent::Disconnect(realm) => {
                // DISC so the device frees the remote TCP bind; required for
                // subsequent Bind→CONN after a few client cycles.
                ptcp_send(
                    &session,
                    &wire,
                    &socket,
                    PTCPBody::Status(realm, "DISC".to_string()),
                )
                .await;
            }
            PTCPEvent::Data(realm, data) => {
                ptcp_send(
                    &session,
                    &wire,
                    &socket,
                    PTCPBody::Payload(PTCPPayload { realm, data }),
                )
                .await;
            }
        }
    }
}

/**
 * Read data from devices and send it to clients
 */
pub async fn dh_reader(
    session: Arc<Mutex<PTCPSession>>,
    wire: Arc<AsyncMutex<()>>,
    socket: Arc<UdpSocket>,
    channels: Arc<Mutex<HashMap<u32, mpsc::UnboundedSender<Vec<u8>>>>>,
    conn_channels: Arc<Mutex<HashMap<u32, oneshot::Sender<bool>>>>,
) {
    let mut payload_packets: u64 = 0;
    let mut payload_bytes: u64 = 0;
    let mut other_packets: u64 = 0;

    loop {
        let Some(packet) = socket.ptcp_read().await else {
            continue;
        };

        // Peer Empty ACKs: only refresh rmid, no counter / no reply.
        if let PTCPBody::Empty = packet.body {
            session.lock().unwrap().recv(packet);
            continue;
        }

        // Agent sometimes probes with Sync (body 00 03 01 00) while keeping
        // ptcp.sent at 0. Counting those 4 bytes as received and Empty-ACKing
        // them inflates our recv window past peer.sent. After PLAY the agent
        // stops delivering interleaved RTP once the windows disagree.
        // Do not reply Sync→Sync (session reset storm); ignore after handshake.
        if let PTCPBody::Sync = packet.body {
            let lmid = packet.lmid;
            session.lock().unwrap().note_peer_lmid(lmid);
            other_packets += 1;
            continue;
        }

        // Update recv window first, then ACK under the wire lock.
        let packet = session.lock().unwrap().recv(packet);

        // Immediate flow-control ACK: peer only releases its send window when
        // our advertised recv climbs. Wire lock keeps Data/HB from overtaking
        // a stale-sent ACK (reorder freezes media after the first RTP blob).
        ptcp_send(&session, &wire, &socket, PTCPBody::Empty).await;

        match packet.body {
            PTCPBody::Status(realm, status) => {
                println!("PTCP Status realm={:08x} status={}", realm, status);
                if status == "CONN" {
                    if let Some(tx) = conn_channels.lock().unwrap().remove(&realm) {
                        let _ = tx.send(true);
                    } else {
                        println!("CONN for unknown realm {:08x} (ignored)", realm);
                    }
                } else if status == "DISC" {
                    channels.lock().unwrap().remove(&realm);
                }
            }
            PTCPBody::Payload(p) => {
                // Interleaved RTP over RTSP is a raw TCP byte stream inside PTCP.
                // Frames may start mid-payload (not always with '$' / 0x24); always
                // forward bytes in order — never filter on the first byte.
                payload_packets += 1;
                payload_bytes += p.data.len() as u64;
                // Log early packets, then every 50, so slow-relay progress
                // is visible in the app (UI filters on "payload #").
                if payload_packets <= 12 || payload_packets % 50 == 0 {
                    println!(
                        "PTCP payload #{} len={} realm={:08x} head={:02x} total_bytes={}",
                        payload_packets,
                        p.data.len(),
                        p.realm,
                        p.data.first().copied().unwrap_or(0),
                        payload_bytes
                    );
                }

                let tx = {
                    let map = channels.lock().unwrap();
                    map.get(&p.realm).cloned()
                };
                if let Some(tx) = tx {
                    // Unbounded local queue: never drop after ACKing — a drop
                    // corrupts the interleaved RTP TCP bitstream for ffmpeg/VLC.
                    if tx.send(p.data).is_err() {
                        println!("Realm {:08x} unavailable", p.realm);
                    }
                } else {
                    println!("Payload for unknown realm {:08x}", p.realm);
                }
            }
            PTCPBody::Heartbeat => {
                other_packets += 1;
                if other_packets <= 3 || other_packets % 50 == 0 {
                    println!(
                        "PTCP heartbeats/other={} payload_packets={} payload_bytes={}",
                        other_packets, payload_packets, payload_bytes
                    );
                }
            }
            _ => {
                other_packets += 1;
            }
        }
    }
}
