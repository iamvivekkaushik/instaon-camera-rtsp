use aes::Aes256;
use async_trait::async_trait;
use base64::Engine;
use cipher::{KeyIvInit, StreamCipher};
use hmac::{Hmac, Mac};
use md5::{Digest as Md5Digest, Md5};
use ofb::Ofb;
use pbkdf2::pbkdf2_hmac;
use sha1::Digest as Sha1Digest;
use sha2::Sha256;
use std::{collections::HashMap, net::SocketAddrV4, sync::OnceLock};
use tokio::{net::UdpSocket, time};
use xml::reader::{EventReader, XmlEvent};

use crate::ptcp::{PTCPBody, PTCPSession, PTCP};

type Aes256Ofb = Ofb<Aes256>;
type HmacSha256 = Hmac<Sha256>;

const LOCAL_IV: &[u8; 16] = b"2z52*lk9o6HRyJrf";
const INFO_KEY: &[u8; 32] = b"kRjmsUB&ezmdGLL67H#$ojw@XflcaIaf";
const INFO_IV: &[u8; 16] = b"MydvJw*Iw1w&i^kk";

#[derive(Clone, Copy)]
struct CloudAuth {
    server: &'static str,
    username: &'static str,
    userkey: &'static str,
}

#[derive(Clone)]
pub struct DeviceCreds {
    pub username: String,
    pub password: String,
}

static CLOUD: OnceLock<CloudAuth> = OnceLock::new();

pub fn set_cloud(name: &str) {
    let auth = match name {
        "instaon_ctc" => CloudAuth {
            server: "instaonserverctc.com:8800",
            username: "zH4gW1gQ6eZ1bT1sH9yP6fR2f_cbmbap",
            userkey: "dN2cQ9gV2qU0iR3uG0wM8oI9sK0hT9mQ",
        },
        "easy4ip" => CloudAuth {
            server: "www.easy4ipcloud.com:8800",
            username: "cba1b29e32cb17aa46b8ff9e73c7f40b",
            userkey: "996103384cdf19179e19243e959bbf8b",
        },
        // default: InstOn overseas (India / most gCMOB)
        _ => CloudAuth {
            server: "instaonserver.com:8800",
            username: "89d61b61dc9a69fdcc03e4ff3a3be2f5",
            userkey: "993c7d7c95542c684c30ff9a9b831249",
        },
    };
    let _ = CLOUD.set(auth);
    println!("Using cloud {} => {}", name, auth.server);
}

fn cloud() -> CloudAuth {
    *CLOUD.get_or_init(|| CloudAuth {
        server: "instaonserver.com:8800",
        username: "89d61b61dc9a69fdcc03e4ff3a3be2f5",
        userkey: "993c7d7c95542c684c30ff9a9b831249",
    })
}

fn ip_to_bytes(ip: &str) -> Vec<u8> {
    let addr: SocketAddrV4 = ip.parse().unwrap();
    let ip = addr.ip().octets();
    let port = addr.port();

    let mut bytes = Vec::new();
    bytes.extend_from_slice(&port.to_be_bytes());
    bytes.extend_from_slice(&ip);

    bytes.iter().map(|b| !b).collect()
}

fn device_login_key(username: &str, password: &str, randsalt: &str) -> Vec<u8> {
    let material = format!("{username}:Login to {randsalt}:{password}");
    let digest = Md5::digest(material.as_bytes());
    let mut hex = String::with_capacity(32);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(hex, "{:02X}", b);
    }
    hex.into_bytes()
}

fn aes_ofb_crypt(key: &[u8], iv: &[u8], data: &[u8]) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "AES-256 key must be 32 bytes".to_string())?;
    let iv: [u8; 16] = iv
        .try_into()
        .map_err(|_| "AES IV must be 16 bytes".to_string())?;
    let mut buf = data.to_vec();
    let mut cipher = Aes256Ofb::new((&key).into(), (&iv).into());
    cipher.apply_keystream(&mut buf);
    Ok(buf)
}

fn get_device_info(info_b64: &str) -> HashMap<String, serde_json::Value> {
    if info_b64.is_empty() {
        return HashMap::new();
    }
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(info_b64) else {
        println!("Could not base64-decode device info, continuing without a salt.");
        return HashMap::new();
    };
    let Ok(plain) = aes_ofb_crypt(INFO_KEY, INFO_IV, &raw) else {
        println!("Could not decrypt device info, continuing without a salt.");
        return HashMap::new();
    };
    match serde_json::from_slice::<HashMap<String, serde_json::Value>>(&plain) {
        Ok(map) => map,
        Err(_) => {
            println!("Could not decrypt device info, continuing without a salt.");
            HashMap::new()
        }
    }
}

fn get_enc(key: &[u8], nonce: u32, data: &str) -> Result<String, String> {
    let salt = nonce.to_string();
    let mut dk = [0u8; 32];
    pbkdf2_hmac::<Sha256>(key, salt.as_bytes(), 20_000, &mut dk);
    let enc = aes_ofb_crypt(&dk, LOCAL_IV, data.as_bytes())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(enc))
}

fn get_dec(key: &[u8], nonce: u32, data: &str) -> Result<String, String> {
    let salt = nonce.to_string();
    let mut dk = [0u8; 32];
    pbkdf2_hmac::<Sha256>(key, salt.as_bytes(), 20_000, &mut dk);
    let raw = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| e.to_string())?;
    let plain = aes_ofb_crypt(&dk, LOCAL_IV, &raw)?;
    String::from_utf8(plain).map_err(|e| e.to_string())
}

fn get_auth(username: &str, key: &[u8], nonce: u32, randsalt: &str, payload: &str) -> String {
    let curdate = chrono::Utc::now().timestamp();
    let message = format!("{nonce}{curdate}{payload}");
    let mut mac =
        HmacSha256::new_from_slice(key).expect("HMAC can take key of any size");
    mac.update(message.as_bytes());
    let auth = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    let salt = if randsalt.is_empty() {
        String::new()
    } else {
        format!("<RandSalt>{randsalt}</RandSalt>")
    };

    format!(
        "<CreateDate>{curdate}</CreateDate><DevAuth>{auth}</DevAuth><Nonce>{nonce}</Nonce>{salt}<UserName>{username}</UserName>"
    )
}

/// Send PTCP Sync and wait for a Sync reply, skipping stray HTTP/UDP junk
/// (common when a late relay-channel ack lands on the agent socket).
async fn ptcp_sync_handshake(
    socket: &UdpSocket,
    session: &mut PTCPSession,
) -> Result<crate::ptcp::PTCPPacket, String> {
    socket
        .ptcp_request(session.send(PTCPBody::Sync))
        .await;

    let deadline = time::Instant::now() + time::Duration::from_secs(8);
    while time::Instant::now() < deadline {
        let slice = deadline.saturating_duration_since(time::Instant::now());
        if slice.is_zero() {
            break;
        }
        match time::timeout(slice.min(time::Duration::from_secs(2)), socket.ptcp_read()).await {
            Ok(Some(pkt)) if matches!(pkt.body, PTCPBody::Sync) => {
                return Ok(pkt);
            }
            Ok(Some(pkt)) => {
                println!("Ignoring non-Sync PTCP during handshake: {:?}", pkt.body);
            }
            Ok(None) => {
                // parse error (e.g. HTTP leftover) — keep waiting for real Sync
            }
            Err(_) => {
                // brief quiet period; resend Sync once more
                println!("PTCP Sync wait quiet; resending Sync");
                socket
                    .ptcp_request(session.send(PTCPBody::Sync))
                    .await;
            }
        }
    }
    Err("PTCP Sync response missing".to_string())
}

pub async fn p2p_handshake(
    socket: UdpSocket,
    serial: String,
    relay_mode: bool,
    auth_type: u8,
    creds: Option<DeviceCreds>,
) -> Result<(UdpSocket, PTCPSession), String> {
    let mut cseq = 0;
    let main_server = cloud().server;

    socket
        .connect(main_server)
        .await
        .map_err(|e| format!("connect main cloud: {e}"))?;

    socket.dh_request("/probe/p2psrv", None, &mut cseq).await;
    socket.dh_read().await?;

    socket
        .dh_request(
            format!("/online/p2psrv/{}", serial).as_ref(),
            None,
            &mut cseq,
        )
        .await;
    let p2psrv = socket
        .dh_read()
        .await?
        .body
        .ok_or_else(|| "missing body for /online/p2psrv".to_string())?
        .get("body/US")
        .cloned()
        .ok_or_else(|| "missing body/US".to_string())?;

    let socket2 = UdpSocket::bind("0.0.0.0:0")
        .await
        .map_err(|e| format!("bind socket2: {e}"))?;
    socket2
        .connect(&p2psrv)
        .await
        .map_err(|e| format!("connect p2psrv: {e}"))?;

    socket2
        .dh_request(
            format!("/probe/device/{}", serial).as_ref(),
            None,
            &mut cseq,
        )
        .await;
    // Some OEM clouds return 404 for probe even when the device is online.
    let probe = socket2.dh_read_raw().await;
    println!("probe/device => {} {}", probe.code, probe.status);

    socket2
        .dh_request(format!("/info/device/{}", serial).as_ref(), None, &mut cseq)
        .await;
    let info_res = match time::timeout(time::Duration::from_secs(10), socket2.dh_read_raw()).await {
        Ok(r) => r,
        Err(_) => {
            println!("info/device timed out — continuing without salt");
            DHResponse {
                version: "HTTP/1.1".into(),
                code: 598,
                status: "info/device timed out".into(),
                headers: HashMap::new(),
                body: None,
            }
        }
    };
    let mut randsalt = String::new();
    if info_res.code < 300 {
        if let Some(body) = &info_res.body {
            let info_b64 = body.get("body/Info").map(|s| s.as_str()).unwrap_or("");
            let info = get_device_info(info_b64);
            if let Some(serde_json::Value::String(s)) = info.get("randsalt") {
                randsalt = s.clone();
                println!("Device info: {:?}", info);
            } else {
                println!("Device reported no salt, continuing without one.");
            }
        }
    } else {
        println!("Could not read device info: {} {}", info_res.code, info_res.status);
    }

    socket.dh_request("/online/relay", None, &mut cseq).await;
    let relay = match time::timeout(time::Duration::from_secs(10), socket.dh_read()).await {
        Ok(Ok(res)) => res
            .body
            .ok_or_else(|| "missing body for /online/relay".to_string())?
            .get("body/Address")
            .cloned()
            .ok_or_else(|| "missing body/Address".to_string())?,
        Ok(Err(e)) => return Err(e),
        Err(_) => {
            return Err(
                "online/relay timed out — cloud busy or stale P2P session; kill leftover dh-p2p and retry"
                    .to_string(),
            );
        }
    };

    let cid: [u8; 8] = rand::random();
    let local_plain = format!("127.0.0.1:{}", socket.local_addr().unwrap().port());

    let (auth_xml, ipaddr_xml, device_key) = if auth_type > 0 {
        let creds = creds.ok_or_else(|| "auth_type>0 requires credentials".to_string())?;
        let key = device_login_key(&creds.username, &creds.password, &randsalt);
        let nonce = rand::random::<u32>() & 0x7FFF_FFFF;
        let enc_laddr = get_enc(&key, nonce, &local_plain)?;
        let auth = get_auth(&creds.username, &key, nonce, &randsalt, &enc_laddr);
        let ipaddr = format!("<IpEncrptV2>true</IpEncrptV2><LocalAddr>{enc_laddr}</LocalAddr>");
        (auth, ipaddr, Some((key, creds.username)))
    } else {
        (
            String::new(),
            format!("<IpEncrpt>true</IpEncrpt><LocalAddr>{local_plain}</LocalAddr>"),
            None,
        )
    };

    socket
        .dh_request(
            format!("/device/{}/p2p-channel", serial).as_ref(),
            Some(
                format!(
                    "<body>{}<Identify>{}</Identify>{}<version>5.0.0</version></body>",
                    auth_xml,
                    cid.iter()
                        .map(|b| format!("{:x}", b))
                        .collect::<Vec<_>>()
                        .join(" "),
                    ipaddr_xml,
                )
                .as_ref(),
            ),
            &mut cseq,
        )
        .await;
    println!(
        "p2p-channel request sent — setting up relay agent (close gCMOB live view if this hangs)"
    );

    socket2
        .connect(&relay)
        .await
        .map_err(|e| format!("connect relay: {e}"))?;

    socket2.dh_request("/relay/agent", None, &mut cseq).await;
    let data = socket2
        .dh_read_timeout(10)
        .await?
        .body
        .ok_or_else(|| "missing body for /relay/agent".to_string())?;
    let token = data
        .get("body/Token")
        .cloned()
        .ok_or_else(|| "missing body/Token".to_string())?;
    let agent = data
        .get("body/Agent")
        .cloned()
        .ok_or_else(|| "missing body/Agent".to_string())?;
    println!("relay agent = {}", agent);

    socket2
        .connect(&agent)
        .await
        .map_err(|e| format!("connect agent: {e}"))?;

    socket2
        .dh_request(
            format!("/relay/start/{}", token).as_ref(),
            Some("<body><Client>:0</Client></body>"),
            &mut cseq,
        )
        .await;
    socket2.dh_read_timeout(10).await?;

    println!("waiting for p2p-channel reply from device…");
    // Phone live view often holds the only cloud session — this is the common hang
    // point. Bound the wait so the app can surface a useful error.
    let mut res = match time::timeout(time::Duration::from_secs(15), socket.dh_read_raw()).await {
        Ok(r) => r,
        Err(_) => {
            return Err(
                "p2p-channel timed out after 15s — close gCMOB/live view on the phone, \
                 wait a few seconds, then retry (device only allows one P2P channel)"
                    .to_string(),
            );
        }
    };

    if res.code == 100 {
        res = match time::timeout(time::Duration::from_secs(12), socket.dh_read_raw()).await {
            Ok(r) => r,
            Err(_) => {
                return Err(
                    "p2p-channel stuck on 100 Trying — close the phone app live view and retry"
                        .to_string(),
                );
            }
        };
    }

    if res.code >= 400 {
        if res.code == 403 {
            return Err(format!(
                "403 p2p-channel: device requires authentication when creating P2P channel"
            ));
        }
        if res.code == 404 {
            return Err(format!(
                "404 p2p-channel: device not online on cloud {} (or wrong cloud for this SN)",
                main_server
            ));
        }
        return Err(format!("Error response: {} {}", res.code, res.status));
    }

    println!("p2p-channel OK ({})", res.status);

    let data = res
        .body
        .ok_or_else(|| "missing body for p2p-channel".to_string())?;
    let mut device_laddr = data
        .get("body/LocalAddr")
        .cloned()
        .ok_or_else(|| "missing body/LocalAddr".to_string())?;
    let device = data
        .get("body/PubAddr")
        .cloned()
        .ok_or_else(|| "missing body/PubAddr".to_string())?;

    let mut relay_auth = String::new();
    if let Some((key, username)) = &device_key {
        let nonce: u32 = data
            .get("body/Nonce")
            .ok_or_else(|| "missing body/Nonce for auth decrypt".to_string())?
            .parse()
            .map_err(|e| format!("bad Nonce: {e}"))?;
        device_laddr = get_dec(key, nonce, &device_laddr)?;
        relay_auth = get_auth(username, key, nonce, &randsalt, "");
    }

    // not necessary when relay_mode is true, but UDP is connectionless
    socket
        .connect(&device)
        .await
        .map_err(|e| format!("connect device: {e}"))?;

    // relay-channel goes to the main cloud — read its HTTP ack *before*
    // switching the UDP peer to the agent, or a late 37-byte
    // `<body><version>…</version></body>` reply is mistaken for PTCP Sync
    // ("invalid PTCP magic") and the handshake aborts.
    socket2
        .connect(main_server)
        .await
        .map_err(|e| format!("reconnect main: {e}"))?;

    socket2
        .dh_request(
            format!("/device/{}/relay-channel", serial).as_ref(),
            Some(
                format!(
                    "<body>{}<agentAddr>{}</agentAddr></body>",
                    relay_auth, agent
                )
                .as_ref(),
            ),
            &mut cseq,
        )
        .await;
    match time::timeout(time::Duration::from_secs(5), socket2.dh_read_raw()).await {
        Ok(r) => {
            println!("relay-channel => {} {}", r.code, r.status);
        }
        Err(_) => {
            println!("relay-channel ack timed out; continuing with agent session");
        }
    }

    socket2
        .connect(&agent)
        .await
        .map_err(|e| format!("reconnect agent: {e}"))?;

    // Some agents also push a short HTTP banner after accept — drain briefly
    // so it cannot steal the first Sync read.
    match time::timeout(time::Duration::from_millis(400), socket2.dh_read_raw()).await {
        Ok(r) => {
            println!("agent pre-sync => {} {}", r.code, r.status);
        }
        Err(_) => {}
    }

    let mut session = PTCPSession::new();
    let sync = ptcp_sync_handshake(&socket2, &mut session).await?;
    session.recv(sync);

    if relay_mode {
        println!("Using relay path (agent {})", agent);
        return Ok((socket2, session));
    }

    // Attempt direct UDP hole-punch first. If it fails, fall back to the
    // agent/relay session *before* requesting a PTCP sign — asking for the
    // sign can make some agents stop relaying.
    let cookie: [u8; 4] = rand::random();
    let trans_id: [u8; 12] = rand::random();
    let cid_inv: Vec<u8> = cid.iter().map(|b| !b).collect();
    let mut buf = [0u8; 4096];

    println!(">>> {}", socket.peer_addr().unwrap());
    let punch1 = [
        b"\xff\xfe\xff\xe7".to_vec(),
        cookie.to_vec(),
        trans_id.to_vec(),
        b"\x7f\xd5\xff\xf7".to_vec(),
        cid_inv.clone(),
        b"\xff\xfb\xff\xf7\xff\xfe".to_vec(),
        ip_to_bytes(&device),
    ]
    .concat();
    println!(
        "Raw [{}]",
        punch1
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<Vec<_>>()
            .join(" ")
    );
    socket.send(&punch1).await.map_err(|e| e.to_string())?;
    println!("---");

    println!("<<< {}", socket.peer_addr().unwrap());
    let nat_ok = match time::timeout(time::Duration::from_secs(5), socket.recv(&mut buf)).await {
        Ok(Ok(n)) if n >= 20 => {
            println!(
                "Raw [{}]",
                buf[0..n]
                    .iter()
                    .map(|b| format!("{:02x}", b))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            println!("---");
            let rtrans_id = buf[8..20].to_vec();

            println!(">>> {}", socket.peer_addr().unwrap());
            let punch2 = [
                b"\xfe\xfe\xff\xe7".to_vec(),
                cookie.to_vec(),
                rtrans_id,
                b"\x7f\xd6\xff\xf7".to_vec(),
                cid_inv.clone(),
                b"\xff\xfb\xff\xf7\xff\xfe".to_vec(),
                ip_to_bytes(&device_laddr),
            ]
            .concat();
            println!(
                "Raw [{}]",
                punch2
                    .iter()
                    .map(|b| format!("{:02x}", b))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            socket.send(&punch2).await.map_err(|e| e.to_string())?;
            println!("---");

            let mut ok = true;
            for _ in 0..5 {
                println!("<<< {}", socket.peer_addr().unwrap());
                match time::timeout(time::Duration::from_secs(3), socket.recv(&mut buf)).await {
                    Ok(Ok(n)) => {
                        println!(
                            "Raw [{}]",
                            buf[0..n]
                                .iter()
                                .map(|b| format!("{:02x}", b))
                                .collect::<Vec<_>>()
                                .join(" ")
                        );
                        println!("---");
                    }
                    _ => {
                        ok = false;
                        break;
                    }
                }
            }
            ok
        }
        _ => {
            println!("Direct P2P hole-punch timed out.");
            false
        }
    };

    if !nat_ok {
        println!("Falling back to relay/agent path (agent {}).", agent);
        return Ok((socket2, session));
    }

    // Direct path: get sign from agent, then finish PTCP auth with the device.
    socket2
        .ptcp_request(session.send(PTCPBody::Command(
            b"\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_vec(),
        )))
        .await;
    let mut res = match socket2.ptcp_read().await {
        Some(p) => session.recv(p),
        None => {
            println!("Invalid sign; falling back to relay.");
            return Ok((socket2, session));
        }
    };
    while let PTCPBody::Empty = res.body {
        match socket2.ptcp_read().await {
            Some(p) => res = session.recv(p),
            None => {
                println!("Invalid sign; falling back to relay.");
                return Ok((socket2, session));
            }
        }
    }
    let sign = match res.body {
        PTCPBody::Command(ref c) => c[12..].to_vec(),
        _ => {
            println!("Invalid sign; falling back to relay.");
            return Ok((socket2, session));
        }
    };
    println!(
        "Sign: {}",
        sign.iter()
            .map(|b| format!("{:02x}", b))
            .collect::<Vec<_>>()
            .join("")
    );

    let mut direct_session = PTCPSession::new();
    socket
        .ptcp_request(direct_session.send(PTCPBody::Sync))
        .await;
    let mut res = match socket.ptcp_read().await {
        Some(p) => direct_session.recv(p),
        None => {
            println!("Direct PTCP Sync failed; falling back to relay.");
            return Ok((socket2, session));
        }
    };
    if !matches!(res.body, PTCPBody::Sync) {
        println!("Direct PTCP Sync failed; falling back to relay.");
        return Ok((socket2, session));
    }

    socket
        .ptcp_request(
            direct_session.send(PTCPBody::Command(
                [
                    b"\x19\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_vec(),
                    sign,
                ]
                .concat(),
            )),
        )
        .await;

    res = match socket.ptcp_read().await {
        Some(p) => direct_session.recv(p),
        None => {
            println!("Direct PTCP auth failed; falling back to relay.");
            return Ok((socket2, session));
        }
    };
    while let PTCPBody::Empty = res.body {
        match socket.ptcp_read().await {
            Some(p) => res = direct_session.recv(p),
            None => {
                println!("Direct PTCP auth failed; falling back to relay.");
                return Ok((socket2, session));
            }
        }
    }
    match res.body {
        PTCPBody::Command(ref c) if c.first() == Some(&0x1A) => {}
        _ => {
            println!("Direct PTCP auth failed; falling back to relay.");
            return Ok((socket2, session));
        }
    }

    socket
        .ptcp_request(direct_session.send(PTCPBody::Command(
            b"\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_vec(),
        )))
        .await;
    res = match socket.ptcp_read().await {
        Some(p) => direct_session.recv(p),
        None => {
            println!("Direct PTCP finalize failed; falling back to relay.");
            return Ok((socket2, session));
        }
    };
    if !matches!(res.body, PTCPBody::Empty) {
        println!("Direct PTCP finalize failed; falling back to relay.");
        return Ok((socket2, session));
    }

    println!("Using direct P2P path to {}", device);
    Ok((socket, direct_session))
}

#[derive(Debug)]
#[allow(dead_code)]
struct DHResponse {
    version: String,
    code: u16,
    status: String,
    headers: HashMap<String, String>,
    body: Option<HashMap<String, String>>,
}

impl DHResponse {
    fn parse_body(body: &str) -> HashMap<String, String> {
        let mut parser = EventReader::from_str(body);
        let mut stack = Vec::new();
        let mut tree = HashMap::new();

        loop {
            match parser.next() {
                Ok(XmlEvent::StartElement { name, .. }) => {
                    stack.push(name.local_name);
                }
                Ok(XmlEvent::EndElement { .. }) => {
                    stack.pop().unwrap();
                }
                Ok(XmlEvent::Characters(s)) => {
                    let key = stack.as_slice().join("/");
                    tree.insert(key, s);
                }
                Ok(XmlEvent::EndDocument) => {
                    break;
                }
                Err(e) => panic!("Error: {}", e),
                _ => {}
            }
        }

        tree
    }

    fn parse_response(res: &str) -> DHResponse {
        let mut parts = res.split("\r\n\r\n");
        let head = parts.next().unwrap();
        let body = parts.next().unwrap_or("");

        let mut head_parts = head.split("\r\n");
        let mut status_line = head_parts.next().unwrap().split(' ');
        let version = status_line.next().unwrap().to_string();
        let code = status_line.next().unwrap().parse::<u16>().unwrap();
        let status = status_line.next().unwrap_or("").to_string();

        let mut headers = HashMap::new();
        for line in head_parts {
            let mut parts = line.splitn(2, ": ");
            if let (Some(key), Some(value)) = (parts.next(), parts.next()) {
                headers.insert(key.to_string(), value.to_string());
            }
        }

        let body = match body.trim().len() {
            0 => None,
            _ => Some(DHResponse::parse_body(body)),
        };

        DHResponse {
            version,
            code,
            status,
            headers,
            body,
        }
    }
}

#[async_trait]
trait DHP2P {
    async fn dh_request(&self, path: &str, body: Option<&str>, seq: &mut u32);
    async fn dh_read_raw(&self) -> DHResponse;

    async fn dh_read(&self) -> Result<DHResponse, String> {
        let res = self.dh_read_raw().await;

        if res.code >= 300 {
            return Err(format!("Error response: {} {}", res.code, res.status));
        }

        Ok(res)
    }

    async fn dh_read_timeout(&self, secs: u64) -> Result<DHResponse, String> {
        match time::timeout(time::Duration::from_secs(secs), self.dh_read()).await {
            Ok(r) => r,
            Err(_) => Err(format!("DH read timed out after {secs}s")),
        }
    }
}

#[async_trait]
impl DHP2P for UdpSocket {
    async fn dh_request(&self, path: &str, body: Option<&str>, seq: &mut u32) {
        let method = match body {
            Some(_) => "DHPOST",
            None => "DHGET",
        };

        let body = match body {
            Some(s) => s,
            None => "",
        };

        let nonce = rand::random::<u32>();
        let currdate = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let auth = cloud();
        let pwd = format!(
            "{}{}DHP2P:{}:{}",
            nonce, currdate, auth.username, auth.userkey
        );

        let mut hasher = sha1::Sha1::new();
        hasher.update(pwd);
        let hash_digest = Sha1Digest::finalize(hasher);
        let digest = base64::engine::general_purpose::STANDARD.encode(&hash_digest);

        *seq += 1;

        let req = format!(
            "\
            {} {} HTTP/1.1\r\n\
            CSeq: {}\r\n\
            Authorization: WSSE profile=\"UsernameToken\"\r\n\
            X-WSSE: UsernameToken Username=\"{}\", PasswordDigest=\"{}\", Nonce=\"{}\", Created=\"{}\"\r\n\r\n{}",
            method, path, seq, auth.username, digest, nonce, currdate, body,
        );

        println!(">>> {}", self.peer_addr().unwrap());
        println!("{}", req);
        println!("---");

        self.send(req.as_bytes()).await.unwrap();
    }

    async fn dh_read_raw(&self) -> DHResponse {
        println!("### {}", self.peer_addr().unwrap());

        let mut buf = [0u8; 4096];
        // Prefer Result over unwrap so a closed socket surfaces as empty/error
        // rather than panicking the binary under the macOS app.
        let n = match self.recv(&mut buf).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("DH UDP recv failed: {e}");
                return DHResponse {
                    version: "HTTP/1.1".into(),
                    code: 599,
                    status: format!("recv failed: {e}"),
                    headers: HashMap::new(),
                    body: None,
                };
            }
        };
        let res = String::from_utf8_lossy(&buf[0..n]);

        println!("<<< {}", self.peer_addr().unwrap());
        println!("{}", res);
        println!("---");

        let res = DHResponse::parse_response(&res);
        println!("{:?}", res);

        res
    }
}
