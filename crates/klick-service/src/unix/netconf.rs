//! Системный прокси и DNS на macOS.
//!
//! Настройки сети в macOS общие для всех пользователей, живут у каждой сетевой службы
//! (Wi-Fi, Ethernet, USB-модем, Thunderbolt Bridge…) и меняются только с правами администратора.
//! Поэтому, в отличие от Windows, прокси ставит служба (она работает от root), а не окно.
//! Настройки переживают выход из программы и перезагрузку: всё, что kl!ck поменял, записано
//! в отметку на диске, и служба возвращает прежнее при отключении, после сбоя и при запуске.
//!
//! DNS в режиме VPN (TUN): ядро перехватывает запросы к порту 53 только внутри адаптера, а DNS-сервер
//! из локальной сети (обычно роутер 192.168.x.1) macOS спрашивает мимо адаптера. Без подмены имена
//! заблокированных сайтов отвечал бы провайдер. На время VPN служба ставит DNS 198.18.0.2 — этот адрес
//! ведёт в адаптер, и ядро отвечает само. Если ядро упадёт, DNS не заработает мимо VPN, пока служба
//! не вернёт прежний, — утечки нет.

use klick_proto::SystemProxy;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

const NETWORKSETUP: &str = "/usr/sbin/networksetup";
/// DNS на время VPN: адрес внутри адаптера TUN (у адаптера 198.18.0.1/30).
pub const DNS_ADDR: &str = "198.18.0.2";
/// Отметки в папке данных службы.
pub const PROXY_MARKER: &str = "sysproxy.json";
pub const DNS_MARKER: &str = "dns.json";

/// Куда ходить мимо прокси: сам компьютер и локальная сеть.
pub const BYPASS: [&str; 9] = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1", "fe80::/10"];

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    enabled: bool,
    server: String,
    port: u16,
}

/// Настройки прокси одной сетевой службы.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct ServiceProxy {
    web: Entry,
    secure: Entry,
    socks: Entry,
    bypass: Vec<String>,
    /// Адрес сценария настройки (PAC), если он включён.
    auto_url: Option<String>,
    auto_discovery: bool,
}

impl ServiceProxy {
    fn ours(&self, port: u16) -> bool {
        self.web.enabled && self.web.server == "127.0.0.1" && self.web.port == port
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct ProxyBackup {
    port: u16,
    services: BTreeMap<String, ServiceProxy>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct DnsBackup {
    /// Пустой список — DNS приходил от роутера (DHCP), своих адресов не было.
    services: BTreeMap<String, Vec<String>>,
}

fn run(args: &[&str]) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let out = std::process::Command::new(NETWORKSETUP).args(args).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    // networksetup часто завершается с кодом 0 и пишет ошибку в stdout.
    if !out.status.success() || text.contains("** Error") {
        tracing::debug!("networksetup {}: {}", args.first().copied().unwrap_or(""), text.trim());
        return None;
    }
    Some(text)
}

/// Включённые сетевые службы: «Wi-Fi», «Ethernet», «USB 10/100/1000 LAN»…
fn services() -> Vec<String> {
    run(&["-listallnetworkservices"]).map(|t| parse_services(&t)).unwrap_or_default()
}

fn parse_services(text: &str) -> Vec<String> {
    text.lines()
        .filter(|l| !l.contains("asterisk (*)") && !l.starts_with('*'))
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

fn parse_entry(text: &str) -> Entry {
    let mut e = Entry::default();
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else { continue };
        let v = v.trim();
        match k.trim() {
            "Enabled" => e.enabled = v.eq_ignore_ascii_case("yes"),
            "Server" => e.server = v.to_string(),
            "Port" => e.port = v.parse().unwrap_or(0),
            _ => {}
        }
    }
    e
}

/// Список доменов, IP-адресов или «There aren't any …».
fn parse_list(text: &str) -> Vec<String> {
    if text.contains("There aren't any") {
        return Vec::new();
    }
    text.lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_string).collect()
}

fn parse_auto_url(text: &str) -> Option<String> {
    let mut url = None;
    let mut enabled = false;
    for line in text.lines() {
        match line.split_once(':').map(|(k, v)| (k.trim(), v.trim())) {
            Some(("URL", v)) if v != "(null)" && !v.is_empty() => url = Some(v.to_string()),
            Some(("Enabled", v)) => enabled = v.eq_ignore_ascii_case("yes"),
            _ => {}
        }
    }
    url.filter(|_| enabled)
}

fn read_service(svc: &str) -> Option<ServiceProxy> {
    Some(ServiceProxy {
        web: parse_entry(&run(&["-getwebproxy", svc])?),
        secure: parse_entry(&run(&["-getsecurewebproxy", svc])?),
        socks: parse_entry(&run(&["-getsocksfirewallproxy", svc])?),
        bypass: run(&["-getproxybypassdomains", svc]).map(|t| parse_list(&t)).unwrap_or_default(),
        auto_url: run(&["-getautoproxyurl", svc]).and_then(|t| parse_auto_url(&t)),
        auto_discovery: run(&["-getproxyautodiscovery", svc]).is_some_and(|t| t.to_ascii_lowercase().contains(": on")),
    })
}

fn set_list(flag: &str, svc: &str, list: &[String]) {
    let mut args = vec![flag, svc];
    if list.is_empty() {
        args.push("Empty");
    } else {
        args.extend(list.iter().map(String::as_str));
    }
    run(&args);
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn write_json<T: Serialize>(path: &Path, v: &T) {
    if let Ok(bytes) = serde_json::to_vec_pretty(v) {
        if let Err(e) = crate::storage::write_atomic(path, &bytes) {
            tracing::warn!("отметка {} не записалась: {e:#}", path.display());
        }
    }
}

/// Поставить прокси kl!ck всем включённым сетевым службам. Повторный вызов (сменилась сеть,
/// появился USB-модем) досылает прокси новым службам и не затирает сохранённые прежние настройки.
pub fn proxy_apply(spec: &SystemProxy, marker: &Path) -> bool {
    let list = services();
    if list.is_empty() {
        return false;
    }
    let mut backup: ProxyBackup = read_json(marker).unwrap_or_default();
    backup.port = spec.port;
    let mut current = Vec::new();
    for svc in list {
        let Some(now) = read_service(&svc) else { continue };
        // Прокси уже наш, а отметки нет (служба упала до записи): вернуть потом — значит выключить.
        backup.services.entry(svc.clone()).or_insert_with(|| if now.ours(spec.port) { ServiceProxy::default() } else { now.clone() });
        current.push((svc, now));
    }
    // Сначала отметка, потом настройки: при сбое посередине служба знает, что возвращать.
    write_json(marker, &backup);
    let port = spec.port.to_string();
    let bypass: Vec<String> = spec.bypass.clone();
    for (svc, now) in current {
        let done = now.ours(spec.port)
            && now.secure == now.web
            && now.socks == now.web
            && now.bypass == bypass
            && now.auto_url.is_none()
            && !now.auto_discovery;
        if done {
            continue;
        }
        run(&["-setwebproxy", &svc, &spec.host, &port]);
        run(&["-setsecurewebproxy", &svc, &spec.host, &port]);
        run(&["-setsocksfirewallproxy", &svc, &spec.host, &port]);
        set_list("-setproxybypassdomains", &svc, &bypass);
        // Сценарий настройки и автообнаружение на время VPN выключаем: браузер сначала пробует их.
        if now.auto_url.is_some() {
            run(&["-setautoproxystate", &svc, "off"]);
        }
        if now.auto_discovery {
            run(&["-setproxyautodiscovery", &svc, "off"]);
        }
    }
    true
}

/// Снять прокси kl!ck: вернуть то, что было. Службы, где прокси уже сменили на чужой, не трогаем.
pub fn proxy_clear(marker: &Path) -> bool {
    let Some(backup) = read_json::<ProxyBackup>(marker) else { return false };
    let mut changed = false;
    for (svc, saved) in &backup.services {
        let Some(now) = read_service(svc) else { continue };
        if !now.ours(backup.port) {
            continue;
        }
        restore_entry(svc, "-setwebproxy", "-setwebproxystate", &saved.web);
        restore_entry(svc, "-setsecurewebproxy", "-setsecurewebproxystate", &saved.secure);
        restore_entry(svc, "-setsocksfirewallproxy", "-setsocksfirewallproxystate", &saved.socks);
        set_list("-setproxybypassdomains", svc, &saved.bypass);
        if let Some(url) = &saved.auto_url {
            run(&["-setautoproxyurl", svc, url]);
        }
        if saved.auto_discovery {
            run(&["-setproxyautodiscovery", svc, "on"]);
        }
        changed = true;
    }
    let _ = std::fs::remove_file(marker);
    changed
}

fn restore_entry(svc: &str, set: &str, state: &str, e: &Entry) {
    if !e.server.is_empty() && e.port > 0 {
        run(&[set, svc, &e.server, &e.port.to_string()]);
    }
    if !e.enabled || e.server.is_empty() {
        run(&[state, svc, "off"]);
    }
}

/// DNS 198.18.0.2 всем включённым сетевым службам на время VPN (TUN).
pub fn dns_apply(marker: &Path) -> bool {
    let list = services();
    if list.is_empty() {
        return false;
    }
    let mut backup: DnsBackup = read_json(marker).unwrap_or_default();
    let mut current = Vec::new();
    for svc in list {
        let Some(now) = run(&["-getdnsservers", &svc]).map(|t| parse_list(&t)) else { continue };
        let ours = now.len() == 1 && now[0] == DNS_ADDR;
        backup.services.entry(svc.clone()).or_insert_with(|| if ours { Vec::new() } else { now.clone() });
        current.push((svc, ours));
    }
    write_json(marker, &backup);
    let mut changed = false;
    for (svc, ours) in current {
        if !ours {
            run(&["-setdnsservers", &svc, DNS_ADDR]);
            changed = true;
        }
    }
    if changed {
        flush_dns_cache();
    }
    true
}

/// Вернуть DNS, который стоял до VPN. Где DNS уже сменили на чужой, не трогаем.
pub fn dns_restore(marker: &Path) -> bool {
    let Some(backup) = read_json::<DnsBackup>(marker) else { return false };
    let mut changed = false;
    for (svc, saved) in &backup.services {
        let Some(now) = run(&["-getdnsservers", svc]).map(|t| parse_list(&t)) else { continue };
        if now.len() == 1 && now[0] == DNS_ADDR {
            set_list("-setdnsservers", svc, saved);
            changed = true;
        }
    }
    let _ = std::fs::remove_file(marker);
    if changed {
        flush_dns_cache();
    }
    changed
}

/// Забыть ответы, полученные через VPN: подменные адреса 198.18.x.x без ядра никуда не ведут.
fn flush_dns_cache() {
    if !cfg!(target_os = "macos") {
        return;
    }
    let _ = std::process::Command::new("/usr/bin/dscacheutil").arg("-flushcache").status();
    let _ = std::process::Command::new("/usr/bin/killall").args(["-HUP", "mDNSResponder"]).status();
}

/// После сбоя службы или при удалении: вернуть прокси и DNS по отметкам.
pub fn restore_leftovers(data: &Path) -> (bool, bool) {
    (proxy_clear(&data.join(PROXY_MARKER)), dns_restore(&data.join(DNS_MARKER)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn networksetup_output_is_parsed() {
        let list = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Bluetooth PAN\nThunderbolt Bridge\nUSB 10/100/1000 LAN\n";
        assert_eq!(parse_services(list), vec!["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN"]);

        let web = parse_entry("Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\nAuthenticated Proxy Enabled: 0\n");
        assert_eq!(web, Entry { enabled: true, server: "127.0.0.1".into(), port: 7890 });
        assert!(ServiceProxy { web, ..Default::default() }.ours(7890));
        let off = parse_entry("Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n");
        assert_eq!(off, Entry::default());

        assert!(parse_list("There aren't any bypass domains set on Wi-Fi.\n").is_empty());
        assert_eq!(parse_list("*.local\n169.254/16\n"), vec!["*.local", "169.254/16"]);
        assert!(parse_list("There aren't any DNS Servers set on Wi-Fi.\n").is_empty());
        assert_eq!(parse_list("198.18.0.2\n"), vec![DNS_ADDR]);

        assert_eq!(parse_auto_url("URL: (null)\nEnabled: No\n"), None);
        assert_eq!(parse_auto_url("URL: http://wpad/proxy.pac\nEnabled: Yes\n").as_deref(), Some("http://wpad/proxy.pac"));
        assert_eq!(parse_auto_url("URL: http://wpad/proxy.pac\nEnabled: No\n"), None);
    }

    #[test]
    fn missing_marker_means_nothing_to_restore() {
        let dir = std::env::temp_dir().join(format!("klick-netconf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(restore_leftovers(&dir), (false, false));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
