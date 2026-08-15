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

/// ACK under the wire lock immediately after applying `recv`, so a concurrent
/// Data/Heartbeat cannot advertise a stale window mid-update.
async fn ptcp_recv_and_ack(
    session: &Arc<Mutex<PTCPSession>>,
    wire: &Arc<AsyncMutex<()>>,
    socket: &Arc<UdpSocket>,
    packet: crate::ptcp::PTCPPacket,
) -> crate::ptcp::PTCPPacket {
    let _wire = wire.lock().await;
    // One session lock for recv + both ACKs: throughput is window/RTT, so every
    // millisecond shaved off the ACK path directly buys media bandwidth.
    let (packet, ack1, ack2) = {
        let mut session = session.lock().unwrap();
        let packet = session.recv(packet);
        // Duplicate ACK: Empty ACKs are tiny UDP datagrams and loss freezes the
        // agent's ~8KiB send window after PLAY (RTP stops around payload #12).
        let ack1 = session.send(PTCPBody::Empty);
        let ack2 = session.send(PTCPBody::Empty);
        (packet, ack1, ack2)
    };
    socket.ptcp_request(ack1).await;
    socket.ptcp_request(ack2).await;
    packet
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
                // Heartbeat advertises current recv; also send a pure Empty so
                // agents that only advance their window on Empty still unlock.
                ptcp_send(&session, &wire, &socket, PTCPBody::Empty).await;
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

fn forward_payload(
    channels: &Arc<Mutex<HashMap<u32, mpsc::UnboundedSender<Vec<u8>>>>>,
    p: PTCPPayload,
    payload_packets: &mut u64,
    payload_bytes: &mut u64,
) {
    *payload_packets += 1;
    *payload_bytes += p.data.len() as u64;
    // Keep the hot path quiet — println through a full Swift pipe stalls ACKs.
    if *payload_packets <= 8 || *payload_packets % 100 == 0 {
        println!(
            "PTCP payload #{} len={} realm={:08x} head={:02x} total_bytes={}",
            *payload_packets,
            p.data.len(),
            p.realm,
            p.data.first().copied().unwrap_or(0),
            *payload_bytes
        );
    }

    let tx = {
        let map = channels.lock().unwrap();
        map.get(&p.realm).cloned()
    };
    if let Some(tx) = tx {
        if tx.send(p.data).is_err() {
            println!("Realm {:08x} unavailable", p.realm);
        }
    } else {
        println!("Payload for unknown realm {:08x}", p.realm);
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
            session.lock().unwrap().note_peer_lmid(packet.lmid);
            continue;
        }

        // Agent sometimes probes with Sync (body 00 03 01 00) while keeping
        // ptcp.sent at 0. Counting those 4 bytes as received and Empty-ACKing
        // them inflates our recv window past peer.sent. After PLAY the agent
        // stops delivering interleaved RTP once the windows disagree.
        if let PTCPBody::Sync = packet.body {
            let lmid = packet.lmid;
            session.lock().unwrap().note_peer_lmid(lmid);
            other_packets += 1;
            continue;
        }

        let packet = ptcp_recv_and_ack(&session, &wire, &socket, packet).await;

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
                forward_payload(&channels, p, &mut payload_packets, &mut payload_bytes);
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
