// Post-17 async operations requiring idevice + tokio.

use std::io::Write;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::str::FromStr;

use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::debug_proxy::DebugProxyClient;
use idevice::mobile_image_mounter::ImageMounter;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::usbmuxd::UsbmuxdConnection;
use idevice::IdeviceService;
use log::{debug, error, info};
use once_cell::sync::Lazy;
use tokio::runtime::{self, Runtime};

use crate::constants;

static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    runtime::Builder::new_multi_thread()
        .enable_io()
        .enable_time()
        .build()
        .unwrap()
});

async fn get_provider() -> Result<TcpProvider, i32> {
    let mut uc = UsbmuxdConnection::new(
        Box::new(
            tokio::net::TcpStream::connect(constants::MUXER_ADDR)
                .await
                .map_err(|_| 1i32)?,
        ),
        0,
    );

    let dev = uc
        .get_devices()
        .await
        .ok()
        .and_then(|x| x.into_iter().next())
        .ok_or(1i32)?;

    let dev = dev.to_provider(
        idevice::usbmuxd::UsbmuxdAddr::TcpSocket(std::net::SocketAddr::V4(
            SocketAddrV4::from_str(constants::MUXER_ADDR).unwrap(),
        )),
        0,
        "asdf",
    );

    Ok(TcpProvider {
        addr: std::net::IpAddr::V4(Ipv4Addr::from_str(constants::DEVICE_IP).unwrap()),
        pairing_file: dev.get_pairing_file().await.unwrap(),
        label: "minimuxer".to_string(),
    })
}

/// Post-17 JIT: CoreDeviceProxy → DVT → ProcessControl → DebugProxy
/// Returns 0 on success, 1-11 on specific failures.
pub(crate) fn debug_app_post17(app_id: String) -> i32 {
    RUNTIME.block_on(async move {
        let provider = match get_provider().await {
            Ok(p) => p,
            Err(e) => return e,
        };

        let proxy = match CoreDeviceProxy::connect(&provider).await {
            Ok(p) => p,
            Err(e) => { error!("CoreDeviceProxy: {:?}", e); return 2; }
        };

        let rsd_port = proxy.handshake.server_rsd_port;
        let mut adapter = match proxy.create_software_tunnel() {
            Ok(a) => a,
            Err(e) => { error!("SoftwareTunnel: {:?}", e); return 3; }
        };

        if let Err(e) = adapter.connect(rsd_port).await {
            error!("RemoteXPC connect: {:?}", e); return 4;
        }

        let xpc_client = match idevice::xpc::XPCDevice::new(adapter).await {
            Ok(x) => x,
            Err(e) => { error!("XPC handshake: {:?}", e); return 5; }
        };

        let dvt_port = match xpc_client.services.get(idevice::dvt::SERVICE_NAME) {
            Some(s) => s.port, None => return 6,
        };
        let debug_proxy_port = match xpc_client.services.get(idevice::debug_proxy::SERVICE_NAME) {
            Some(s) => s.port, None => return 6,
        };

        let mut adapter = xpc_client.into_inner();
        if let Err(e) = adapter.close().await { error!("XPC close: {:?}", e); return 7; }

        if let Err(e) = adapter.connect(dvt_port).await {
            error!("DVT connect: {:?}", e); return 4;
        }

        let mut rs = idevice::dvt::remote_server::RemoteServerClient::new(adapter);
        if let Err(e) = rs.read_message(0).await { error!("DVT read: {:?}", e); return 8; }

        let mut pc = match idevice::dvt::process_control::ProcessControlClient::new(&mut rs).await {
            Ok(p) => p,
            Err(e) => { error!("ProcessControl: {:?}", e); return 9; }
        };

        let pid = match pc.launch_app(app_id, None, None, true, false).await {
            Ok(p) => p,
            Err(e) => { error!("LaunchApp: {:?}", e); return 10; }
        };
        debug!("Launched PID {pid}");
        let _ = pc.disable_memory_limit(pid).await;

        let mut adapter = rs.into_inner();
        if let Err(e) = adapter.close().await { error!("DVT close: {:?}", e); return 7; }

        info!("Connecting to debug proxy port {debug_proxy_port}");
        if let Err(e) = adapter.connect(debug_proxy_port).await {
            error!("DebugProxy connect: {:?}", e); return 4;
        }

        let mut dp = DebugProxyClient::new(adapter);
        for cmd in [format!("vAttach;{pid:02X}"), "D".into(), "D".into(), "D".into(), "D".into()] {
            match dp.send_command(cmd.into()).await {
                Ok(res) => debug!("cmd res: {res:?}"),
                Err(e) => { error!("DebugProxy cmd: {:?}", e); return 11; }
            }
        }
        0
    })
}

/// Post-17 personalized DDI mount from pre-downloaded bytes.
/// Returns 0 on success, 1-8 on specific failures.
pub(crate) fn mount_personalized_ddi(
    image_bytes: &[u8],
    trustcache_bytes: &[u8],
    manifest_bytes: &[u8],
) -> i32 {
    RUNTIME.block_on(async move {
        let provider = match get_provider().await {
            Ok(p) => p,
            Err(e) => return e,
        };

        let mut lockdown = match idevice::lockdown::LockdownClient::connect(&provider).await {
            Ok(l) => l,
            Err(e) => { error!("Lockdown connect: {:?}", e); return 4; }
        };

        let ucid_val = match lockdown.get_value("UniqueChipID").await {
            Ok(u) => u,
            Err(_) => {
                if let Err(e) = lockdown.start_session(&provider.get_pairing_file().await.unwrap()).await {
                    error!("Session: {:?}", e); return 4;
                }
                match lockdown.get_value("UniqueChipID").await {
                    Ok(l) => l,
                    Err(e) => { error!("UniqueChipID: {:?}", e); return 5; }
                }
            }
        };
        let unique_chip_id = match ucid_val.as_unsigned_integer() {
            Some(i) => i,
            None => { error!("UniqueChipID not int"); return 5; }
        };

        let mut mounter = match ImageMounter::connect(&provider).await {
            Ok(m) => m,
            Err(e) => { error!("ImageMounter: {:?}", e); return 6; }
        };

        let images = match mounter.copy_devices().await {
            Ok(i) => i,
            Err(e) => { error!("copy_devices: {:?}", e); return 6; }
        };
        if !images.is_empty() { info!("Already mounted"); return 0; }

        info!("Mounting personalized DDI...");
        if let Err(e) = mounter.mount_personalized_with_callback(
            &provider,
            image_bytes.to_vec(),
            trustcache_bytes.to_vec(),
            manifest_bytes,
            None,
            unique_chip_id,
            async |((n, d), _)| {
                let pct = (n as f64 / d as f64) * 100.0;
                print!("\rProgress: {pct:.2}%");
                std::io::stdout().flush().unwrap();
                if n == d { println!(); }
            },
            (),
        ).await {
            error!("Mount failed: {:?}", e); return 8;
        }

        info!("DDI mounted");
        0
    })
}
