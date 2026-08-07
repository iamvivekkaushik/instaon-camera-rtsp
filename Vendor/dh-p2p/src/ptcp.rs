use async_trait::async_trait;
use std::cmp;
use std::os::fd::AsRawFd;
use tokio::net::UdpSocket;

/// Grow kernel UDP buffers so interleaved RTP bursts after PLAY are not
/// dropped while the async loop is busy ACKing / writing TCP.
///
/// Tokio's UdpSocket in this crate's lockfile has no set_recv_buffer_size;
/// use libc setsockopt on the raw fd.
pub fn set_udp_buffers(socket: &UdpSocket) {
    let fd = socket.as_raw_fd();
    // 4 MiB request; kernel may clamp to net.core.rmem_max / wmem_max.
    let size: libc::c_int = 4 * 1024 * 1024;
    unsafe {
        let r = libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &size as *const _ as *const libc::c_void,
            std::mem::size_of_val(&size) as libc::socklen_t,
        );
        if r != 0 {
            eprintln!("SO_RCVBUF set failed: {}", std::io::Error::last_os_error());
        }
        let r = libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            &size as *const _ as *const libc::c_void,
            std::mem::size_of_val(&size) as libc::socklen_t,
        );
        if r != 0 {
            eprintln!("SO_SNDBUF set failed: {}", std::io::Error::last_os_error());
        }
    }
}

pub enum PTCPEvent {
    Heartbeat,
    Connect(u32),
    Disconnect(u32),
    Data(u32, Vec<u8>),
}

pub struct PTCPPayload {
    pub realm: u32,
    pub data: Vec<u8>,
}

pub enum PTCPBody {
    Sync,
    Command(Vec<u8>),
    Payload(PTCPPayload),
    Bind(u32, u32),
    Status(u32, String),
    Heartbeat,
    Empty,
}

pub struct PTCPPacket {
    sent: u32,
    recv: u32,
    pid: u32,
    pub lmid: u32,
    rmid: u32,
    pub body: PTCPBody,
}

impl PTCPPayload {
    fn parse(data: &[u8]) -> Result<PTCPPayload, String> {
        if data.len() < 12 {
            return Err(format!("payload too short: {}", data.len()));
        }
        if data[0] != 0x10 {
            return Err(format!("invalid payload type {:02x}", data[0]));
        }

        // first 4 bytes it header
        let header = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
        let length = header & 0xFFFF;
        let realm = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
        let padding = u32::from_be_bytes([data[8], data[9], data[10], data[11]]);
        let data = data[12..].to_vec();

        if padding != 0 {
            return Err(format!("invalid padding {padding}"));
        }
        if length != data.len() as u32 {
            // Truncated UDP datagrams used to panic here and kill the tunnel
            // right as interleaved RTP started flowing.
            return Err(format!(
                "length mismatch: header={length} body={} (datagram truncated?)",
                data.len()
            ));
        }

        Ok(PTCPPayload { realm, data })
    }

    fn serialize(&self) -> Vec<u8> {
        let length = self.data.len() as u32;
        let header = 0x10000000 | length;
        let header = header.to_be_bytes();
        let realm = self.realm.to_be_bytes();
        let padding = 0u32.to_be_bytes();

        [
            header.to_vec(),
            realm.to_vec(),
            padding.to_vec(),
            self.data.clone(),
        ]
        .concat()
    }
}

impl std::fmt::Debug for PTCPPayload {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "length: {}, realm: 0x{:08x}, data: [{}{}]",
            self.data.len(),
            self.realm,
            self.data[0..cmp::min(self.data.len(), 16)]
                .iter()
                .map(|b| format!("{:02x}", b))
                .collect::<Vec<_>>()
                .join(" "),
            if self.data.len() > 16 { " ..." } else { "" },
        )
    }
}

impl std::fmt::Debug for PTCPBody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PTCPBody::Sync => write!(f, "Sync"),
            PTCPBody::Command(data) => write!(
                f,
                "Command([{}])",
                data.iter()
                    .map(|b| format!("{:02x}", b))
                    .collect::<Vec<_>>()
                    .join(" ")
            ),
            PTCPBody::Payload(payload) => write!(f, "{:?}", payload),
            PTCPBody::Bind(realm, port) => {
                write!(f, "Bind {{ realm: 0x{:08x}, port: {} }}", realm, port)
            }
            PTCPBody::Status(realm, status) => {
                write!(f, "Status {{ realm: 0x{:08x}, status: {} }}", realm, status)
            }
            PTCPBody::Heartbeat => write!(f, "Heartbeat"),
            PTCPBody::Empty => write!(f, "Empty"),
        }
    }
}

impl std::fmt::Debug for PTCPPacket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "PTCPPacket {{ sent: {}, recv: {}, pid: 0x{:08x}, lmid: 0x{:08x}, rmid: 0x{:08x}, body: {:?} }}",
            self.sent, self.recv, self.pid, self.lmid, self.rmid, self.body
        )
    }
}

impl PTCPBody {
    fn parse(data: &[u8]) -> Result<PTCPBody, String> {
        if data.is_empty() {
            return Ok(PTCPBody::Empty);
        }

        if data.len() < 4 {
            return Err(format!("body too short: {}", data.len()));
        }

        Ok(match data[0] {
            0x00 => PTCPBody::Sync,
            0x10 => PTCPBody::Payload(PTCPPayload::parse(data)?),
            0x11 => {
                if data.len() < 16 {
                    return Err(format!("bind body too short: {}", data.len()));
                }
                PTCPBody::Bind(
                    u32::from_be_bytes([data[4], data[5], data[6], data[7]]),
                    u32::from_be_bytes([data[12], data[13], data[14], data[15]]),
                )
            }
            0x12 => {
                let realm = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
                let status = String::from_utf8_lossy(&data[12..]).to_string();
                PTCPBody::Status(realm, status)
            }
            0x13 => PTCPBody::Heartbeat,
            _ => PTCPBody::Command(data.to_vec()),
        })
    }

    fn serialize(&self) -> Vec<u8> {
        match self {
            PTCPBody::Sync => b"\x00\x03\x01\x00".to_vec(),
            PTCPBody::Command(data) => data.to_vec(),
            PTCPBody::Payload(payload) => payload.serialize(),
            PTCPBody::Bind(realm, port) => [
                b"\x11\x00\x00\x00".to_vec(),
                realm.to_be_bytes().to_vec(),
                b"\x00\x00\x00\x00".to_vec(),
                port.to_be_bytes().to_vec(),
                b"\x7f\x00\x00\x01".to_vec(),
            ]
            .concat(),
            PTCPBody::Status(realm, status) => [
                b"\x12\x00\x00\x00".to_vec(),
                realm.to_be_bytes().to_vec(),
                b"\x00\x00\x00\x00".to_vec(),
                status.as_bytes().to_vec(),
            ]
            .concat(),
            PTCPBody::Heartbeat => b"\x13\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_vec(),
            PTCPBody::Empty => Vec::new(),
        }
    }

    fn len(&self) -> usize {
        match self {
            PTCPBody::Sync => 4,
            PTCPBody::Command(data) => data.len(),
            PTCPBody::Payload(payload) => payload.data.len() + 12,
            PTCPBody::Bind(_, _) => 20,
            PTCPBody::Status(_, status) => status.len() + 12,
            PTCPBody::Heartbeat => 12,
            PTCPBody::Empty => 0,
        }
    }
}

impl PTCPPacket {
    fn parse(data: &[u8]) -> Result<PTCPPacket, String> {
        if data.len() < 24 {
            return Err(format!("packet too short: {}", data.len()));
        }

        if &data[0..4] != b"PTCP" {
            return Err("invalid PTCP magic".to_string());
        }

        let sent = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
        let recv = u32::from_be_bytes([data[8], data[9], data[10], data[11]]);
        let pid = u32::from_be_bytes([data[12], data[13], data[14], data[15]]);
        let lmid = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
        let rmid = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
        let body = PTCPBody::parse(&data[24..])?;

        Ok(PTCPPacket {
            sent,
            recv,
            pid,
            lmid,
            rmid,
            body,
        })
    }

    fn serialize(&self) -> Vec<u8> {
        [
            b"PTCP".to_vec(),
            self.sent.to_be_bytes().to_vec(),
            self.recv.to_be_bytes().to_vec(),
            self.pid.to_be_bytes().to_vec(),
            self.lmid.to_be_bytes().to_vec(),
            self.rmid.to_be_bytes().to_vec(),
            self.body.serialize(),
        ]
        .concat()
    }

    fn try_print_data(&self) {
        if let PTCPBody::Payload(p) = &self.body {
            // Only log RTSP control text. Interleaved RTP ($...) and binary
            // media must stay off the hot path — println per frame stalls the
            // UDP reader, drops datagrams, and corrupts the TCP bitstream.
            let is_rtsp = p.data.starts_with(b"RTSP/")
                || p.data.starts_with(b"OPTIONS")
                || p.data.starts_with(b"DESCRIBE")
                || p.data.starts_with(b"SETUP")
                || p.data.starts_with(b"PLAY")
                || p.data.starts_with(b"TEARDOWN")
                || p.data.starts_with(b"GET_PARAMETER")
                || p.data.starts_with(b"SET_PARAMETER")
                || p.data.starts_with(b"PAUSE")
                || p.data.starts_with(b"ANNOUNCE")
                || p.data.starts_with(b"RECORD");
            if is_rtsp {
                if let Some(split) = p.data.windows(4).position(|w| w == b"\r\n\r\n") {
                    let header_end = split + 4;
                    println!("{}", String::from_utf8_lossy(&p.data[..header_end]));
                    if header_end < p.data.len() {
                        let rest = &p.data[header_end..];
                        println!(
                            "... +{} trailing bytes after RTSP headers (first={:02x})",
                            rest.len(),
                            rest.first().copied().unwrap_or(0)
                        );
                    }
                } else {
                    println!("{}", String::from_utf8_lossy(&p.data));
                }
            }
        }
    }
}

pub struct PTCPSession {
    sent: u32,
    recv: u32,
    count: u32,
    id: u32,
    rmid: u32,
}

impl PTCPSession {
    pub fn new() -> PTCPSession {
        PTCPSession {
            sent: 0,
            recv: 0,
            count: 0,
            id: 0,
            rmid: 0,
        }
    }

    pub fn send(&mut self, body: PTCPBody) -> PTCPPacket {
        // PTCP flow control: `sent` / `recv` are cumulative payload-body byte
        // counts (like TCP seq/ack). Empty ACKs carry the latest `recv` so the
        // peer may free its send window; they do not advance `sent` or count.
        // Callers must not reorder wire transmits relative to counter updates
        // (see process::ptcp_send).
        let sent = self.sent;
        let recv = self.recv;
        let pid = match body {
            PTCPBody::Sync => 0x0002FFFF,
            _ => 0x0000FFFF - self.count,
        };
        let lmid = self.id;
        let rmid = self.rmid;

        /*
         * Update counters
         */
        self.sent += body.len() as u32;

        self.id += 1;
        self.count += match body {
            PTCPBody::Sync => 0,
            PTCPBody::Empty => 0,
            _ => 1,
        };

        PTCPPacket {
            sent,
            recv,
            pid,
            lmid,
            rmid,
            body,
        }
    }

    pub fn recv(&mut self, packet: PTCPPacket) -> PTCPPacket {
        // Advance local recv window by the body length we actually accepted.
        // Payload length includes the 12-byte 0x10 realm header (not just RTP).
        self.recv += packet.body.len() as u32;
        self.rmid = packet.lmid;

        packet
    }

    /// Track peer lmid without moving the byte-oriented flow-control window.
    /// Used for peer Session Sync probes (agent keeps sent=0 on those).
    pub fn note_peer_lmid(&mut self, lmid: u32) {
        self.rmid = lmid;
    }
}

#[async_trait]
pub trait PTCP {
    async fn ptcp_request(&self, packet: PTCPPacket);
    async fn ptcp_read(&self) -> Option<PTCPPacket>;
}

fn should_trace(packet: &PTCPPacket) -> bool {
    match &packet.body {
        PTCPBody::Payload(p) => {
            p.data.starts_with(b"RTSP/")
                || p.data.starts_with(b"OPTIONS")
                || p.data.starts_with(b"DESCRIBE")
                || p.data.starts_with(b"SETUP")
                || p.data.starts_with(b"PLAY")
                || p.data.starts_with(b"TEARDOWN")
                || p.data.starts_with(b"GET_PARAMETER")
                || p.data.starts_with(b"SET_PARAMETER")
        }
        PTCPBody::Bind(_, _) | PTCPBody::Status(_, _) | PTCPBody::Sync | PTCPBody::Command(_) => {
            true
        }
        PTCPBody::Heartbeat | PTCPBody::Empty => false,
    }
}

#[async_trait]
impl PTCP for UdpSocket {
    async fn ptcp_request(&self, packet: PTCPPacket) {
        let trace = should_trace(&packet);
        if trace {
            println!(">>> {}", self.peer_addr().unwrap());
            println!("{:?}", packet);
            packet.try_print_data();
            println!("---");
        }

        let packet = packet.serialize();
        if let Err(e) = self.send(&packet).await {
            eprintln!("PTCP send failed: {e}");
        }
    }

    async fn ptcp_read(&self) -> Option<PTCPPacket> {
        // Must fit max UDP payload; 4KiB truncated media frames and panicked
        // the parser right when RTP-over-TCP started.
        let mut buf = [0u8; 65536];
        let n = match self.recv(&mut buf).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("PTCP recv failed: {e}");
                return None;
            }
        };

        match PTCPPacket::parse(&buf[0..n]) {
            Ok(packet) => {
                if should_trace(&packet) {
                    println!("<<< {}", self.peer_addr().unwrap());
                    println!("{:?}", packet);
                    packet.try_print_data();
                    println!("---");
                }
                Some(packet)
            }
            Err(e) => {
                eprintln!("PTCP parse error ({n} bytes): {e}");
                None
            }
        }
    }
}
