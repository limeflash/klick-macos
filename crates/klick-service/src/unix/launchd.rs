//! Служба macOS: демон launchd. Регистрация, запуск по команде launchd, остановка по SIGTERM.
//!
//! Установленная служба живёт отдельно от окна, в папке, которую может менять только root:
//! `/Library/PrivilegedHelperTools/klick` (служба, ядро, наборы). Запускать от root файл из
//! `/Applications`, куда пишет любой администратор без пароля, небезопасно.
//! Ядро остаётся в группе процессов службы: если служба упадёт, launchd завершит его вместе с ней
//! (так же, как объект задания на Windows).

use crate::paths::{Paths, Profile};
use crate::{engine, netconf, pipe, sys};
use anyhow::{bail, Context, Result};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const LABEL: &str = "app.klick.service";
pub const PLIST: &str = "/Library/LaunchDaemons/app.klick.service.plist";
/// Папка установленной службы.
pub const INSTALL_DIR: &str = "/Library/PrivilegedHelperTools/klick";
const SERVICE_EXE: &str = "klick-service";
const CORE_EXE: &str = "mihomo";
const LAUNCHCTL: &str = "/bin/launchctl";

/// Точка входа демона; запускает launchd (`klick-service run`).
pub fn run_dispatcher() -> Result<()> {
    if !sys::is_elevated() {
        bail!("`run` запускает launchd от root; для разработки — `klick-service console`");
    }
    let paths = Paths::production()?;
    paths.ensure_dirs()?;
    crate::init_file_log(&paths)?;
    sys::raise_fd_limit();
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let profile = Profile::production();
        let (engine, _task) = engine::spawn(paths, profile.clone())?;
        let mut server = tokio::spawn(pipe::serve(profile.pipe.clone(), true, engine.clone()));
        let mut term = signal(SignalKind::terminate())?;
        let mut int = signal(SignalKind::interrupt())?;
        tracing::info!("служба запущена (pid {})", std::process::id());
        tokio::select! {
            _ = term.recv() => tracing::info!("SIGTERM: останавливаюсь"),
            _ = int.recv() => tracing::info!("SIGINT: останавливаюсь"),
            r = &mut server => match r {
                Ok(Err(e)) => tracing::error!("канал управления упал: {e:#}"),
                _ => tracing::error!("канал управления остановился"),
            },
        }
        // Выключение Mac или `launchctl bootout`: вернуть прокси и DNS, остановить ядро.
        engine.shutdown().await;
        server.abort();
        let _ = std::fs::remove_file(&profile.pipe);
        anyhow::Ok(())
    })
}

/// Где лежат файлы для установки: рядом с этим exe в пакете `.app` (`Contents/MacOS` и
/// `Contents/Resources/resources`), в папке сборки (`target/release` и `resources` проекта).
struct Source {
    service: PathBuf,
    core: PathBuf,
    resources: PathBuf,
}

fn find_source() -> Result<Source> {
    let service = std::env::current_exe()?.canonicalize()?;
    let dir = service.parent().context("нет папки exe")?.to_path_buf();
    let mut cores = vec![dir.join(CORE_EXE)];
    let mut resources = vec![dir.join("resources"), dir.join("../Resources/resources")];
    for up in dir.ancestors().skip(1).take(4) {
        cores.push(up.join("resources/core").join(CORE_EXE));
        resources.push(up.join("resources"));
    }
    let core = cores.into_iter().find(|p| p.is_file()).context("не нашёл ядро mihomo рядом со службой (scripts/macos/fetch-core.sh)")?;
    let resources = resources.into_iter().find(|p| p.join("catalog.json").is_file()).context("не нашёл папку resources с catalog.json")?;
    Ok(Source { service, core, resources })
}

/// Установить службу: скопировать в `/Library/PrivilegedHelperTools/klick`, зарегистрировать в launchd, запустить.
/// Повторный запуск обновляет установленную службу: VPN вернётся сам, если был включён.
pub fn install() -> Result<()> {
    if !sys::is_elevated() {
        bail!("нужны права администратора: sudo klick-service install");
    }
    let src = find_source()?;
    let target = Path::new(INSTALL_DIR);
    let staging = target.with_extension("new");
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    copy_file(&src.service, &staging.join(SERVICE_EXE), 0o755)?;
    copy_file(&src.core, &staging.join(CORE_EXE), 0o755)?;
    copy_dir(&src.resources, &staging.join("resources"))?;
    // Ядро в папке ресурсов для службы не нужно: оно лежит рядом со службой.
    let _ = std::fs::remove_file(staging.join("resources/core").join(CORE_EXE));
    let _ = std::fs::remove_file(staging.join("resources/core/mihomo.exe"));

    stop();
    if target.exists() {
        std::fs::remove_dir_all(target).with_context(|| format!("не удалить старую {}", target.display()))?;
    }
    std::fs::rename(&staging, target)?;
    own_tree(target)?;
    // Файлы из загрузок macOS помечает карантином: у службы его быть не должно.
    let _ = Command::new("/usr/bin/xattr").args(["-dr", "com.apple.quarantine", INSTALL_DIR]).status();

    // Папка данных нужна до запуска: в неё launchd пишет ошибки службы.
    let data = Path::new(crate::paths::DATA_DIR);
    std::fs::create_dir_all(data.join("logs"))?;
    sys::restrict_to_admins(data)?;

    std::fs::write(PLIST, plist())?;
    std::os::unix::fs::chown(PLIST, Some(0), Some(0))?;
    std::fs::set_permissions(PLIST, std::fs::Permissions::from_mode(0o644))?;
    launchctl(&["bootstrap", "system", PLIST]).context("launchctl bootstrap")?;
    let _ = launchctl(&["enable", &format!("system/{LABEL}")]);
    println!("служба {LABEL} установлена в {INSTALL_DIR} и запущена");
    Ok(())
}

/// Остановить и удалить службу. `wipe` — удалить и данные (подключения, настройки, журнал).
pub fn uninstall(wipe: bool) -> Result<()> {
    if !sys::is_elevated() {
        bail!("нужны права администратора: sudo klick-service uninstall");
    }
    stop();
    let _ = std::fs::remove_file(PLIST);
    // Служба при остановке сама возвращает прокси и DNS; если она была мертва — вернуть по отметкам.
    let data = Path::new(crate::paths::DATA_DIR);
    let _ = netconf::restore_leftovers(data);
    let _ = std::fs::remove_file(klick_proto::SOCKET);
    if Path::new(INSTALL_DIR).exists() {
        std::fs::remove_dir_all(INSTALL_DIR)?;
    }
    if wipe && data.exists() {
        std::fs::remove_dir_all(data)?;
    }
    println!("служба {LABEL} удалена{}", if wipe { " вместе с данными" } else { "" });
    Ok(())
}

/// Вернуть прокси и DNS, которые поменял kl!ck (по отметкам в папке данных).
pub fn cleanup_network() -> Result<()> {
    if !sys::is_elevated() {
        bail!("нужны права администратора");
    }
    let (proxy, dns) = netconf::restore_leftovers(Path::new(crate::paths::DATA_DIR));
    println!("прокси возвращён: {} · DNS возвращён: {}", if proxy { "да" } else { "нечего" }, if dns { "да" } else { "нечего" });
    Ok(())
}

/// Выгрузить службу из launchd и дождаться, пока она остановится (она успевает вернуть прокси и DNS).
fn stop() {
    let target = format!("system/{LABEL}");
    if launchctl(&["print", &target]).is_err() {
        return;
    }
    let _ = launchctl(&["bootout", &target]);
    for _ in 0..100 {
        if launchctl(&["print", &target]).is_err() {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    eprintln!("служба не остановилась за 20 с");
}

fn launchctl(args: &[&str]) -> Result<()> {
    let out = Command::new(LAUNCHCTL).args(args).output().context("launchctl")?;
    if !out.status.success() {
        bail!("launchctl {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn plist() -> String {
    let log = Path::new(crate::paths::DATA_DIR).join("logs/launchd.log");
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{INSTALL_DIR}/{SERVICE_EXE}</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ExitTimeOut</key>
    <integer>20</integer>
    <key>StandardErrorPath</key>
    <string>{log}</string>
</dict>
</plist>
"#,
        log = log.display()
    )
}

fn copy_file(from: &Path, to: &Path, mode: u32) -> Result<()> {
    std::fs::copy(from, to).with_context(|| format!("копирование {} → {}", from.display(), to.display()))?;
    std::fs::set_permissions(to, std::fs::Permissions::from_mode(mode))?;
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from).with_context(|| format!("{}", from.display()))?.flatten() {
        let path = e.path();
        let dst = to.join(e.file_name());
        if e.file_type()?.is_dir() {
            copy_dir(&path, &dst)?;
        } else {
            copy_file(&path, &dst, 0o644)?;
        }
    }
    Ok(())
}

/// Всё в папке службы принадлежит root:wheel: подменить файлы может только администратор через sudo.
fn own_tree(path: &Path) -> Result<()> {
    std::os::unix::fs::chown(path, Some(0), Some(0))?;
    if path.is_dir() {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))?;
        for e in std::fs::read_dir(path)?.flatten() {
            own_tree(&e.path())?;
        }
    }
    Ok(())
}
