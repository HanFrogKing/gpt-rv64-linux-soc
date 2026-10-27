"""Per-build RV64 PCH cleanup. Never edits frozen gates or deletes evidence."""
import datetime
import json
from pathlib import Path
import shutil


def install(common, driver, phase):
    root = common.ROOT / 'build/rv64' / phase
    assert root.resolve() == root and phase.startswith('r50-')
    audit = Path('${HOST_OUTPUTS}/storage-audit-20261024')
    audit.mkdir(parents=True, exist_ok=True)
    original_run, original_emit = common.run, common.emit
    identities = {
        str(Path(__file__).resolve().relative_to(common.ROOT)): common.sha(__file__),
        str(driver.resolve().relative_to(common.ROOT)): common.sha(driver),
    }

    def cleanup(tag, directory):
        count = allocated = 0
        for p in directory.rglob('*.gch'):
            if p.is_symlink() or p.resolve() != p:
                raise RuntimeError('Unsafe cache path: ' + str(p))
            if '__pch.h.' not in p.name:
                continue
            header = p.with_name(p.name.split('__pch.h.', 1)[0] + '__pch.h')
            if not header.is_file() or not list(p.parent.glob('*__verFiles.dat')):
                continue
            st = p.stat()
            allocated += st.st_blocks * 512
            p.unlink()
            count += 1
        if count:
            record = dict(timestamp=datetime.datetime.now().astimezone().isoformat(),
                          phase=phase, tag=tag, removed=count, allocated_bytes=allocated)
            with (audit/'automatic-pch-cleanup.jsonl').open('a') as f:
                f.write(json.dumps(record) + '\n')
            print(f'CACHE_CLEANUP {tag}: {count} PCH files, {allocated} bytes', flush=True)

    def run(tag, cmd, **kwargs):
        is_build = Path(str(cmd[0])).name == 'verilator' and '--build' in cmd
        if is_build:
            arguments = [str(value) for value in cmd]
            common.require('--Mdir' in arguments, 'Build must name its model directory')
            directory = Path(arguments[arguments.index('--Mdir') + 1])
            common.require(directory.is_absolute() and directory.is_relative_to(root)
                           and directory.resolve() == directory, 'Unsafe model directory')
            # Restrict cleanup to this completed command, allowing other model
            # directories to compile independently without deleting their PCH.
            cleanup('before-' + tag, directory)
            common.require(shutil.disk_usage('/mnt/e').free >= 10 * 1024**3,
                           'E: free space below 10 GiB; stop before compiling')
            common.require(shutil.disk_usage('/').free >= 5 * 1024**3,
                           'WSL free space below 5 GiB; stop before compiling')
        try:
            return original_run(tag, cmd, **kwargs)
        finally:
            if is_build:
                cleanup('after-' + tag, directory)

    def emit(p, data):
        p = Path(p)
        if p.name == 'run-status.json' and p.is_relative_to(root):
            status = json.loads(data)
            # Bind the automatic cleanup policy and the actual adapted driver.
            if 'source_sha256' in status:
                status['source_sha256'].update(identities)
            status['artifact_guard_sha256'] = identities
            data = json.dumps(status, indent=2) + '\n'
        original_emit(p, data)

    common.run, common.emit = run, emit
