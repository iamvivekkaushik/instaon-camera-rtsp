use clap::Parser;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::{
    net::{TcpListener, UdpSocket},
    sync::{mpsc, oneshot, Mutex as AsyncMutex, Semaphore},
};

use crate::{
    dh::{p2p_handshake, set_cloud, DeviceCreds},
    process::{dh_reader, dh_writer, process_reader, process_writer},
    ptcp::{set_udp_buffers, PTCPEvent},
};

mod dh;
mod process;
mod ptcp;

fn die(code: i32, msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(code);
}

#[derive(Parser)]
#[command(about = "A PoC implementation of TCP tunneling over Dahua P2P protocol.", long_about = None)]
struct Cli {
    /// Bind address, port and remote port. Default: 127.0.0.1:1554:554
    #[arg(short, long, value_name = "[bind_address:]port:remote_port")]
    port: Option<String>,
    /// Relay mode (experimental)
    #[arg(short, long)]
    relay: bool,
    /// P2P cloud: instaon | instaon_ctc | easy4ip
    #[arg(short = 'c', long, default_value = "instaon")]
    cloud: String,
    /// Channel auth type: 0=none, 1=device login, auto=try 0 then 1
    #[arg(short = 't', long, default_value = "auto")]
    r#type: String,
    /// Device username (required for -t 1 / auto on auth-required devices)
    #[arg(short = 'u', long)]
    username: Option<String>,
    /// Device password (required for -t 1 / auto on auth-required devices)
    #[arg(long)]
    password: Option<String>,
    /// Serial number of the camera
    serial: String,
}

#[tokio::main]
async fn main() {
    let args = Cli::parse();
    set_cloud(&args.cloud);

    let serial = args.serial;
    let port = args.port.unwrap_or("127.0.0.1:1554:554".to_string());

    let parts: Vec<&str> = port.split(':').collect();
    let (bind_address, bind_port, remote_port): (&str, u16, u16) = match parts.len() {
        2 => (
            "127.0.0.1",
            parts[0].parse().unwrap(),
            parts[1].parse().unwrap(),
        ),
        3 => (
            parts[0],
            parts[1].parse().unwrap(),
            parts[2].parse().unwrap(),
        ),
        _ => die(2, "Invalid port specification"),
    };

    let creds = match (&args.username, &args.password) {
        (Some(u), Some(p)) => Some(DeviceCreds {
            username: u.clone(),
            password: p.clone(),
        }),
        (None, None) => None,
        _ => die(2, "Both --username and --password are required together"),
    };

    let auth_modes: Vec<u8> = match args.r#type.as_str() {
        "0" => vec![0],
        "1" => {
            if creds.is_none() {
                die(2, "-t 1 requires --username and --password");
            }
            vec![1]
        }
        "auto" => {
            if creds.is_some() {
                vec![0, 1]
            } else {
                vec![0]
            }
        }
        other => die(2, &format!("Invalid -t/--type {other} (use 0, 1, or auto)")),
    };

    // Bind the listener to the address
    let listener = match TcpListener::bind(format!("{}:{}", bind_address, bind_port)).await {
        Ok(l) => l,
        Err(e) => die(1, &format!("Failed to bind {bind_address}:{bind_port}: {e}")),
    };

    let mut last_err = String::from("handshake failed");
    let mut established: Option<(UdpSocket, crate::ptcp::PTCPSession)> = None;

    for mode in auth_modes {
        println!("Attempting P2P handshake auth_type={}", mode);
        let socket = match UdpSocket::bind("0.0.0.0:0").await {
            Ok(s) => s,
            Err(e) => die(1, &format!("UDP bind failed: {e}")),
        };
        // Enlarge buffers before connect/handshake so early PTCP media isn't
        // dropped while the event loop is busy (or before reader task runs).
        set_udp_buffers(&socket);

        match p2p_handshake(
            socket,
            serial.clone(),
            args.relay,
            mode,
            creds.clone(),
        )
        .await
        {
            Ok(pair) => {
                established = Some(pair);
                break;
            }
            Err(e) => {
                last_err = e.clone();
                eprintln!("Handshake failed (auth_type={}): {}", mode, e);
                if mode == 0 && e.contains("403") && creds.is_some() {
                    println!("Retrying with device authentication (-t 1)…");
                    continue;
                }
            }
        }
    }

    let (socket, session) = match established {
        Some(v) => v,
        None => die(1, &format!("P2P tunnel failed: {last_err}")),
    };
    set_udp_buffers(&socket);

    let (dh_tx, dh_rx) = mpsc::channel::<PTCPEvent>(4096);
    let session = Arc::new(Mutex::new(session));
    // Wire lock: one PTCP send (assemble + UDP) at a time — see process::ptcp_send.
    let wire = Arc::new(AsyncMutex::new(()));

    let channels =
        Arc::new(Mutex::new(HashMap::<u32, mpsc::UnboundedSender<Vec<u8>>>::new()));
    let conn_channels = Arc::new(Mutex::new(HashMap::<u32, oneshot::Sender<bool>>::new()));

    println!("PTCP session established");

    /*
     * Clone the handles
     */

    let reader = Arc::new(socket);
    let writer = reader.clone();

    let session2 = session.clone();
    let wire2 = wire.clone();
    let channels2 = channels.clone();
    let conn_channels2 = conn_channels.clone();

    let hb_tx = dh_tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
            let _ = hb_tx.send(PTCPEvent::Heartbeat).await;
        }
    });

    tokio::spawn(async move {
        dh_writer(session, wire, writer, dh_rx, remote_port.into()).await;
    });

    tokio::spawn(async move {
        dh_reader(session2, wire2, reader, channels, conn_channels).await;
    });

    // Concurrent local RTSP clients (multiview). PTCP demuxes by realm id.
    // Cap prevents runaway accepts; serialize Bind→CONN so overlapping setups
    // do not leave zombie realms that stall the next handshake.
    let max_clients: usize = std::env::var("DH_P2P_MAX_CLIENTS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(16);
    let client_slots = Arc::new(Semaphore::new(max_clients));
    let bind_setup = Arc::new(AsyncMutex::new(()));
    println!("P2P multiview: up to {} concurrent RTSP clients", max_clients);

    // Only signal ready after reader/writer tasks are running.
    println!("Ready to connect!");
    println!("CAMERA_STREAMER_TUNNEL_READY");
    if remote_port == 554 {
        println!(
            "RTSP URL: rtsp://127.0.0.1{}/cam/realmonitor?channel=1&subtype=0",
            if bind_port != 554 {
                format!(":{}", bind_port)
            } else {
                String::new()
            }
        );
    }

    loop {
        // The second item contains the IP and port of the new connection.
        let (client, addr) = listener.accept().await.unwrap();
        println!("Accepted connection from {}", addr);

        let permit = match client_slots.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => break,
        };

        // Create a channel for the client
        let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (conn_tx, conn_rx) = oneshot::channel::<bool>();
        let dh_tx = dh_tx.clone();
        let channels_client = channels2.clone();
        let conn_for_cleanup = conn_channels2.clone();
        let bind_setup = bind_setup.clone();

        let realm_id = rand::random::<u32>();

        // Store the channel in the map
        channels_client.lock().unwrap().insert(realm_id, tx);
        conn_channels2.lock().unwrap().insert(realm_id, conn_tx);

        // One Bind handshake at a time; many realms may stream in parallel after CONN.
        let setup_ok = {
            let _setup = bind_setup.lock().await;
            println!("PTCP Bind realm={:08x} → remote port", realm_id);
            if dh_tx.send(PTCPEvent::Connect(realm_id)).await.is_err() {
                false
            } else {
                match tokio::time::timeout(tokio::time::Duration::from_secs(20), conn_rx).await {
                    Ok(Ok(true)) => {
                        println!("PTCP CONN ok realm={:08x}", realm_id);
                        true
                    }
                    Ok(Ok(false)) | Ok(Err(_)) | Err(_) => false,
                }
            }
        };

        if !setup_ok {
            eprintln!(
                "Timed out waiting for PTCP CONN on realm {:08x} — closing client {}",
                realm_id, addr
            );
            channels_client.lock().unwrap().remove(&realm_id);
            conn_for_cleanup.lock().unwrap().remove(&realm_id);
            let _ = dh_tx.send(PTCPEvent::Disconnect(realm_id)).await;
            drop(client);
            drop(permit);
            tokio::time::sleep(tokio::time::Duration::from_millis(300)).await;
            continue;
        }

        let (reader, writer) = client.into_split();
        let channels_reader = channels_client.clone();
        let dh_tx_reader = dh_tx.clone();

        tokio::spawn(async move {
            process_reader(reader, realm_id, dh_tx_reader, channels_reader).await;
            // Hold the slot until teardown (DISC + map cleanup) completes.
            drop(permit);
        });

        tokio::spawn(async move {
            process_writer(writer, rx).await;
        });
    }
}
