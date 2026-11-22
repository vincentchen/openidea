//! `openidea-server --stdio`: the IDE backend for remote development, serving
//! one desktop client over stdin / stdout (started by the client over SSH).

use ide_host::catalogue::TrustClass;
use ide_host::plugins::remote::{RemotePluginLanguages, SYNC_COMMAND};
use ide_host::plugins::remote_host::RemotePlugins;
use ide_host::rpc::{self, Dispatcher};
use ide_host::{Host, HostConfig};
use ide_language::LanguageRegistry;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

fn main() {
    let raw_args: Vec<String> = std::env::args().collect();
    if let Some(project) = ide_mcp::stdio_request(&raw_args) {
        let base = server_home();
        std::process::exit(ide_mcp::stdio::run(&ide_mcp::discovery_path(&base.join("data")), project));
    }
    let args: Vec<String> = raw_args.into_iter().skip(1).collect();
    if args.iter().any(|a| a == "--version") {
        println!("openidea-server {} (protocol {})", env!("CARGO_PKG_VERSION"), rpc::PROTOCOL_VERSION);
        return;
    }
    if args.first().is_some_and(|a| a == "--connect") {
        // One forwarded connection (see `ide_host::relay`): stdout carries its bytes.
        let code = match ide_host::relay::parse_args(&args[1..]).and_then(|(host, port)| {
            ide_host::relay::relay(&host, port, std::io::stdin(), std::io::stdout().lock())
                .map_err(|e| format!("cannot connect to {host}:{port}: {e}"))
        }) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("{e}");
                1
            }
        };
        std::process::exit(code);
    }
    if args.iter().any(|a| a == "--install-tools") {
        std::process::exit(install_tools());
    }
    if !args.iter().any(|a| a == "--stdio") {
        eprintln!(
            "usage: openidea-server --stdio | --mcp-stdio [--project <path>] | --connect <host> <port> | --version \
             | --install-tools"
        );
        std::process::exit(2);
    }
    // stdout carries the protocol: logs go to stderr.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_env("OPENIDEA_LOG").unwrap_or_else(|_| "info".into()))
        .init();
    let base = server_home();
    // An SSH exec channel gets a minimal environment: take the login shell's, read
    // afresh on every start, plus the IDE-managed tools. Before any other thread starts.
    ide_host::shell_env::inherit_login_shell_env("openidea-server");
    let data_dir = base.join("data");
    ide_tools::extend_process_path(&data_dir);
    ide_dap::adapter::set_tools_root(ide_tools::tools_dir(&data_dir));
    ide_sdk::java::add_jdk_root(&ide_tools::jdk::jdks_dir(&data_dir));
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    let code = runtime.block_on(run(base));
    std::process::exit(code);
}

fn server_home() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_default();
    std::env::var_os("OPENIDEA_SERVER_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".openidea"))
}

/// `--install-tools`: installs every managed tool (language servers, debuggers,
/// plugins) and the JDK into `<OPENIDEA_SERVER_HOME>/data`, so the result can be
/// shipped as an offline pack (see `scripts/kylin/bundle-tools.sh`).
///
/// `OPENIDEA_INSTALL_TOOLS_ONLY` / `OPENIDEA_INSTALL_TOOLS_SKIP` narrow the set
/// (comma-separated registry names). One `status<TAB>name<TAB>detail` line per
/// tool goes to stdout and to `data/install-report.tsv`; the exit code is 1 when
/// a tool that should have installed failed.
fn install_tools() -> i32 {
    use ide_tools::{InstallEvent, ToolKind, Tools};

    let base = server_home();
    let (config_dir, data_dir) = (base.join("config"), base.join("data"));
    for dir in [&config_dir, &data_dir] {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("cannot create {}: {e}", dir.display());
            return 1;
        }
    }
    let languages = match LanguageRegistry::load(Some(&config_dir.join("languages"))) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("language definitions: {e}");
            return 1;
        }
    };
    let langs = languages.all();
    let cancel = ide_core::CancellationToken::new();
    let list = |name: &str| -> Vec<String> {
        std::env::var(name).map(|v| v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()).unwrap_or_default()
    };
    let (only, skip) = (list("OPENIDEA_INSTALL_TOOLS_ONLY"), list("OPENIDEA_INSTALL_TOOLS_SKIP"));
    // Progress is noisy for ~60 downloads: one line per tenth.
    let step = std::sync::atomic::AtomicU64::new(11);
    let emit = |e: InstallEvent| match e {
        InstallEvent::Line { text } => eprintln!("  {text}"),
        InstallEvent::Progress { fraction, message } => {
            let Some(f) = fraction else { return };
            let bucket = (f.clamp(0.0, 1.0) * 10.0) as u64;
            if step.swap(bucket, std::sync::atomic::Ordering::Relaxed) != bucket {
                eprintln!("  {message} ({}%)", bucket * 10);
            }
        }
    };
    let mut report = String::new();
    let mut note = |status: &str, name: &str, detail: &str| {
        let line = format!("{status}\t{name}\t{detail}");
        println!("{line}");
        report.push_str(&line);
        report.push('\n');
    };

    // Java first: jdtls, java-debug and the Java language support need a JDK while installing.
    let jdks = ide_tools::jdk::jdks_dir(&data_dir);
    let jdk = Tools::new(&data_dir).download_jdk(ide_tools::jdk::TEMURIN, 21, Some(&jdks), &cancel, &emit);
    match jdk {
        Ok(jdk) => {
            let home: &std::path::Path = jdk.home.as_ref();
            note("ok", "jdk-21", &jdk.version);
            // `which("java")` of the tools below must see it.
            let path = std::env::var_os("PATH").unwrap_or_default();
            let mut dirs = vec![home.join("bin")];
            dirs.extend(std::env::split_paths(&path));
            if let Ok(joined) = std::env::join_paths(dirs) {
                // SAFETY: `--install-tools` is single-threaded up to this point.
                unsafe { std::env::set_var("PATH", joined) };
            }
        }
        Err(e) => {
            note("failed", "jdk-21", &e.to_string());
        }
    }
    let tools = Tools::new(&data_dir);
    let mut failed = 0;
    for spec in ide_tools::TOOLS {
        let name = spec.name;
        if matches!(spec.kind, ToolKind::Cli) {
            continue;
        }
        if !only.is_empty() && !only.iter().any(|n| n == name) {
            continue;
        }
        if skip.iter().any(|n| n == name) {
            note("skipped", name, "OPENIDEA_INSTALL_TOOLS_SKIP");
            continue;
        }
        // Neither is portable: rustup's component lives in the toolchain, and an
        // "active" gem installs into the project, not the tools directory.
        match spec.method {
            ide_tools::Method::Rustup { .. } => {
                note("skipped", name, "needs rustup on the target host");
                continue;
            }
            ide_tools::Method::GemActive { .. } => {
                note("skipped", name, "installs into the project (needs Ruby on the target)");
                continue;
            }
            _ => {}
        }
        let info = match tools.info(name, &langs) {
            Ok(i) => i,
            Err(e) => {
                note("failed", name, &e.to_string());
                failed += 1;
                continue;
            }
        };
        if info.status == ide_tools::ToolStatus::Installed {
            note("present", name, info.version.as_deref().unwrap_or(""));
            continue;
        }
        if !info.can_install {
            note("unavailable", name, info.unavailable_reason.as_deref().unwrap_or(""));
            continue;
        }
        eprintln!("==> {name} ({})", info.display_name);
        match tools.install(name, &langs, &cancel, &emit) {
            Ok(done) => note("ok", name, done.version.as_deref().unwrap_or("")),
            Err(e) => {
                note("failed", name, &e.to_string());
                failed += 1;
            }
        }
    }
    let report_path = data_dir.join("install-report.tsv");
    if let Err(e) = std::fs::write(&report_path, &report) {
        eprintln!("cannot write {}: {e}", report_path.display());
    }
    eprintln!("report: {}", report_path.display());
    if failed > 0 { 1 } else { 0 }
}

async fn run(base: PathBuf) -> i32 {
    let (config_dir, data_dir) = (base.join("config"), base.join("data"));
    for dir in [&config_dir, &data_dir] {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("cannot create {}: {e}", dir.display());
            return 1;
        }
    }
    let languages = match LanguageRegistry::load(Some(&config_dir.join("languages"))) {
        Ok(l) => Arc::new(l),
        Err(e) => {
            eprintln!("language definitions: {e}");
            return 1;
        }
    };
    // The desktop's plugin languages (`plugin_sync_languages`); programs pinned on this machine.
    let plugin_languages = RemotePluginLanguages::new(Some(&data_dir));
    languages.attach_plugins(plugin_languages.store().clone());
    let peer = Arc::new(OnceLock::new());
    let sink_peer = peer.clone();
    let plugins_data = data_dir.clone();
    let host = Arc::new(Host::new(HostConfig {
        config_dir,
        local_data_dir: data_dir.clone(),
        data_dir,
        languages,
        syntax: Arc::default(),
        sink_for: Box::new(move |window| rpc::event_sink(sink_peer.clone(), Some(window.to_owned()))),
        owner: |w| w,
        runtime: tokio::runtime::Handle::current(),
        project_environment: true,
    }));
    // A stable path for `--mcp-stdio` client configurations across server upgrades.
    host.mcp.set_stdio_link(base.join("bin").join("openidea-server"));
    host.mcp_background.serve_none();
    host.mcp.apply(&host);
    // The desktop's code plugins run here, next to the project (`plugin_sync_packages`).
    let plugins = match RemotePlugins::start(&plugins_data, &host, peer.clone()) {
        Ok(p) => Some(p),
        Err(e) => {
            tracing::warn!("plugins are unavailable: {e}");
            None
        }
    };
    if let Some(root) = std::env::var_os(ide_host::trust::TRUSTED_ROOT_ENV)
        && let Err(e) = host.trust.inherit(std::path::Path::new(&root))
    {
        tracing::warn!("cannot trust {}: {e}", root.to_string_lossy());
    }
    tracing::info!("openidea-server {} ready", env!("CARGO_PKG_VERSION"));
    let mut dispatcher = Dispatcher::standard();
    if let Some(plugins) = &plugins {
        plugins.register(&mut dispatcher);
    }
    dispatcher.add(SYNC_COMMAND, TrustClass::Trusted, move |c| {
        let remote = plugin_languages.clone();
        async move {
            let report = remote.sync(c.arg("languages")?);
            c.host.plugin_languages_changed();
            Ok(report)
        }
    });
    rpc::serve(host.clone(), dispatcher, peer, tokio::io::stdin(), tokio::io::stdout()).await;
    host.mcp.stop(&host);
    if let Some(plugins) = &plugins {
        plugins.host().shutdown();
    }
    // `process::exit` skips destructors: nothing started for the client may outlive it.
    if tokio::time::timeout(std::time::Duration::from_secs(10), host.shutdown()).await.is_err() {
        tracing::warn!("language servers did not shut down in time");
    }
    0
}
