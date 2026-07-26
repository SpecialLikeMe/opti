//! In-house makepkg: takes a PKGBUILD source tree and produces an installable
//! image, without shelling out to Arch's makepkg.
//!
//!   M1  metadata      .SRCINFO, dependency strings, version comparison
//!   M2  sources       fetch, checksum, extract into $srcdir
//!   M3  lifecycle     prepare/build/check/package under fakeroot
//!   M4  artifact      image -> .PKGINFO/.MTREE -> .pkg.tar.zst
//!
//! Only M1 runs without bash. From M3 onward the PKGBUILD's own functions must
//! execute, which is why metadata parsing is kept strictly separate: dependency
//! resolution never needs to run untrusted code.

pub const dep = @import("dep.zig");
pub const srcinfo = @import("srcinfo.zig");
pub const vercmp = @import("vercmp.zig");
pub const verify = @import("verify.zig");
pub const exec = @import("exec.zig");
pub const fetch = @import("fetch.zig");
pub const extract = @import("extract.zig");
pub const sources = @import("sources.zig");
pub const archive = @import("archive.zig");
pub const tidy = @import("tidy.zig");
pub const generate = @import("generate.zig");
pub const signature = @import("signature.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const driver = @import("driver.zig");

pub const Dep = dep.Dep;
pub const Op = dep.Op;
pub const SrcInfo = srcinfo.SrcInfo;
pub const Source = srcinfo.Source;
pub const Algorithm = verify.Algorithm;
pub const Stage = lifecycle.Stage;

test {
    _ = dep;
    _ = srcinfo;
    _ = vercmp;
    _ = verify;
    _ = exec;
    _ = fetch;
    _ = extract;
    _ = sources;
    _ = archive;
    _ = tidy;
    _ = generate;
    _ = signature;
    _ = lifecycle;
    _ = driver;
}
