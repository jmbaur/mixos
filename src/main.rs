use std::{
    ffi::CStr,
    io::{BufWriter, Read, Write},
    os::{fd::AsRawFd, unix::process::CommandExt},
    sync::Mutex,
};

use log::{Level, Metadata, Record};

use anyhow::Context;

const LOOP_CTL_GET_FREE: std::ffi::c_int = 0x4C82;
const LOOP_SET_FD: std::ffi::c_int = 0x4C00;

fn mount(
    fstype: Option<&CStr>,
    what: &CStr,
    where_: &CStr,
    flags: u64,
    options: Option<&CStr>,
) -> anyhow::Result<()> {
    log::debug!("mounting {what:?} (fstype {fstype:?}) on {where_:?}");

    let ret = unsafe {
        libc::mount(
            what.as_ptr(),
            where_.as_ptr(),
            match fstype {
                Some(fstype) => fstype.as_ptr(),
                None => std::ptr::null(),
            },
            flags,
            match options {
                Some(options) => options.as_ptr() as *const _,
                None => std::ptr::null(),
            },
        )
    };

    if ret == -1 {
        anyhow::bail!(
            "failed to mount {:?} on {:?}: {}",
            what,
            where_,
            std::io::Error::last_os_error()
        );
    }

    Ok(())
}

fn find_cmdline<'a>(contents: &'a str, want_param: &'static str) -> Option<&'a str> {
    for param in contents.split_ascii_whitespace() {
        let Some((key, value)) = param.split_once('=') else {
            continue;
        };

        if key == want_param {
            return Some(value);
        }
    }

    None
}

const KMSG_USER_FACILITY: u32 = 1 << 3;

struct KmsgLogger {
    prefix: &'static str,
    inner: Mutex<BufWriter<std::fs::File>>,
}

impl KmsgLogger {
    pub fn new(prefix: &'static str) -> anyhow::Result<Self> {
        Self::disable_kmsg_throttle()?;
        let kmsg = std::fs::OpenOptions::new().write(true).open("/dev/kmsg")?;

        Ok(Self {
            prefix,
            inner: Mutex::new(BufWriter::new(kmsg)),
        })
    }

    fn disable_kmsg_throttle() -> anyhow::Result<()> {
        let mut sysctl = std::fs::OpenOptions::new()
            .write(true)
            .open("/proc/sys/kernel/printk_devkmsg")?;

        sysctl.write_all("on\n".as_bytes())?;

        Ok(())
    }
}

impl log::Log for KmsgLogger {
    // We just write the desired loglevel to to kernel log ring buffer and let the kernel do the
    // filtering for us.
    fn enabled(&self, metadata: &Metadata) -> bool {
        _ = metadata;

        true
    }

    fn log(&self, record: &Record) {
        // 0 KERN_EMERG
        // 1 KERN_ALERT
        // 2 KERN_CRIT
        // 3 KERN_ERR
        // 4 KERN_WARNING
        // 5 KERN_NOTICE
        // 6 KERN_INFO
        // 7 KERN_DEBUG
        let level: u32 = match record.level() {
            Level::Error => 3,
            Level::Warn => 4,
            Level::Info => 6,
            Level::Debug => 7,
            Level::Trace => 7,
        };

        let level = KMSG_USER_FACILITY | level;

        let Ok(mut inner) = self.inner.lock() else {
            return;
        };

        _ = writeln!(inner, "<{}>{}: {}", level, self.prefix, record.args());

        // We do the flush here so we don't have to re-obtain the lock on the mutex. The actual
        // flush method becomes a no-op.
        _ = inner.flush();
    }

    fn flush(&self) {}
}

fn loopback_setup(backing_file: &str) -> anyhow::Result<String> {
    log::debug!("finding next loopback index");

    let loop_control = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/loop-control")
        .context("failed to open /dev/loop-control")?;

    let loopnr = unsafe { libc::ioctl(loop_control.as_raw_fd(), LOOP_CTL_GET_FREE.try_into()?) };
    if loopnr == -1 {
        anyhow::bail!("failed to get next loopback index");
    }

    let loop_device_path = format!("/dev/loop{loopnr}");
    log::debug!("using loopback device \"{}\"", &loop_device_path);

    let loop_device = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&loop_device_path)
        .with_context(|| format!("failed to open {loop_device_path}"))?;

    let backing_file = std::fs::canonicalize(backing_file)?;
    log::debug!("using backing file {:?}", &backing_file);

    let backing_file = std::fs::OpenOptions::new()
        .read(true)
        .write(false)
        .open(&backing_file)
        .context("failed to open /rootfs")?;

    log::debug!("setting backing file on loopback device");
    let ret = unsafe {
        libc::ioctl(
            loop_device.as_raw_fd(),
            LOOP_SET_FD.try_into()?,
            TryInto::<i32>::try_into(backing_file.as_raw_fd())?,
        )
    };

    if ret == -1 {
        anyhow::bail!("failed to set backing file");
    }

    Ok(loop_device_path)
}

fn chroot(arg: &'static CStr) -> anyhow::Result<()> {
    match unsafe { libc::chroot(arg.as_ptr()) } {
        -1 => Err(anyhow::anyhow!("chroot failed")),
        _ => Ok(()),
    }
}

fn chdir(arg: &'static CStr) -> anyhow::Result<()> {
    match unsafe { libc::chdir(arg.as_ptr()) } {
        -1 => Err(anyhow::anyhow!("chdir failed")),
        _ => Ok(()),
    }
}

fn switch_root() -> anyhow::Result<()> {
    std::fs::create_dir_all("/dev")?;
    std::fs::create_dir_all("/sys")?;
    std::fs::create_dir_all("/proc")?;

    mount(
        Some(c"devtmpfs"),
        c"devtmpfs",
        c"/dev",
        libc::MS_NOEXEC | libc::MS_NOSUID,
        None,
    )?;

    mount(
        Some(c"sysfs"),
        c"sysfs",
        c"/sys",
        libc::MS_NOEXEC | libc::MS_NOSUID,
        None,
    )?;

    mount(
        Some(c"proc"),
        c"proc",
        c"/proc",
        libc::MS_NODEV | libc::MS_NOSUID,
        None,
    )?;

    // This is the earliest we could setup the logger since we need access to /dev/kmsg
    let logger = KmsgLogger::new("initrd").context("failed to setup kmsg logger")?;
    log::set_boxed_logger(Box::new(logger))?;
    log::set_max_level(log::LevelFilter::Trace);

    let loop_device_path = loopback_setup("/rootfs").context("failed to setup loopback device")?;

    let mut cmdline_file =
        std::fs::File::open("/proc/cmdline").context("failed to open /proc/cmdline")?;
    let mut cmdline = String::new();
    _ = cmdline_file.read_to_string(&mut cmdline)?;
    let cmdline = cmdline.trim();

    log::debug!("using kernel cmdline \"{}\"", &cmdline);

    let init = find_cmdline(cmdline, "init").unwrap_or("/init");
    log::debug!("using init \"{init}\"");

    let rootfstype = find_cmdline(cmdline, "rootfstype").unwrap_or("erofs");
    log::debug!("using root fstype \"{rootfstype}\"");

    std::fs::create_dir_all("/sysroot")?;

    let loop_device_path = std::ffi::CString::new(loop_device_path)?;
    let rootfstype = std::ffi::CString::new(rootfstype)?;

    mount(
        Some(&rootfstype),
        &loop_device_path,
        c"/sysroot",
        libc::MS_RDONLY | libc::MS_NODEV | libc::MS_NOSUID,
        None,
    )?;

    chdir(c"/sysroot")?;

    // ensure the initrd rootfs files don't consume any memory in the real system
    log::debug!("removing remnants of initrd rootfs");
    std::fs::remove_dir_all("/nix")?;
    std::fs::remove_file("/init")?;

    log::debug!("moving pseudofilesystems into final root filesystem");
    mount(None, c"/dev", c"/sysroot/dev", libc::MS_MOVE, None)?;
    mount(None, c"/sys", c"/sysroot/sys", libc::MS_MOVE, None)?;
    mount(None, c"/proc", c"/sysroot/proc", libc::MS_MOVE, None)?;
    mount(None, c".", c"/", libc::MS_MOVE, None)?;

    log::debug!("chrooting into final root filesystem");
    chroot(c".")?;

    log::debug!("executing init of final root filesystem");
    let err = std::process::Command::new(init).exec();

    Err(err).context("failed to execute final root filesystem init")
}

pub fn main() -> ! {
    if let Err(err) = switch_root() {
        // use eprintln here, logging setup might have failed
        eprintln!("{err}");
    }

    // TODO(jared): should we reboot?
    unreachable!("initrd failed")
}
