"""Backed-up, journaled replacement of the installed work launcher bundle.

Shared by scripts/install-work-update-approved.py and its tests. It never touches the
official app, the work profile or any running process.
"""
from pathlib import Path
import ctypes, hashlib, json, os, plistlib, shutil, stat, subprocess, uuid


def require(value, label):
    if not value: raise RuntimeError(label)

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest_digest(value): return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()

def manifest(path):
    require(path.resolve() == path and not path.is_symlink(), 'bundle 경로 불일치')
    values = {}
    for p in [path] + sorted(path.rglob('*')):
        s = p.lstat()
        require(not p.is_symlink() and s.st_uid == os.getuid() and not (s.st_mode & 0o022), 'bundle 소유권/권한/링크 불일치')
        require(stat.S_ISDIR(s.st_mode) or (stat.S_ISREG(s.st_mode) and s.st_nlink == 1), 'bundle 파일 형식 불일치')
        if p.is_file(): values[str(p.relative_to(path))] = [digest(p),stat.S_IMODE(s.st_mode)]
    return values

def sync_directory(p):
    fd = os.open(p,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)

def sync_bundle(p):
    for child in p.rglob('*'):
        if child.is_file():
            fd=os.open(child,os.O_RDONLY|os.O_NOFOLLOW)
            try: os.fsync(fd)
            finally: os.close(fd)
    for child in sorted((x for x in p.rglob('*') if x.is_dir()),key=lambda x:len(x.parts),reverse=True): sync_directory(child)
    sync_directory(p)

def rename_exclusive(source,destination):
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    libc.renamex_np.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    libc.renamex_np.restype=ctypes.c_int
    # sys/stdio.h RENAME_EXCL: never replace an appeared destination.
    if libc.renamex_np(os.fsencode(source),os.fsencode(destination),0x00000004):
        raise OSError(ctypes.get_errno(),'배타 게시 실패')

def journal(path,record):
    tmp=path.parent/('record-'+uuid.uuid4().hex+'.tmp')
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as out:
        json.dump(record,out,indent=2);out.write('\n');out.flush();os.fsync(out.fileno())
    os.replace(tmp,path);sync_directory(path.parent)

def replace(source,destination,old_manifest,new_manifest,old_manifest_sha,new_manifest_sha,verify_signature,check_idle,preflight,checkpoint=lambda phase:None):
    require(manifest_digest(old_manifest)==old_manifest_sha and manifest_digest(new_manifest)==new_manifest_sha,'승인 전체 manifest 변경')
    require(source.parent.stat().st_dev==destination.parent.stat().st_dev,'동일 파일시스템 필요')
    require(manifest(source)==new_manifest and manifest(destination)==old_manifest,'승인 산출물 변경')
    check_idle();preflight();verify_signature(source);verify_signature(destination)
    workspace=destination.parent/('.CodexSplit-work-replacement-'+uuid.uuid4().hex)
    workspace.mkdir(mode=0o700);sync_directory(destination.parent)
    staged,backup=workspace/'candidate.app',workspace/'previous.app'
    record={'phase':'preparing','backup':str(backup),'staging':str(staged),'destination':str(destination),
            'oldManifest':old_manifest,'newManifest':new_manifest,'stateTransitionPerformed':False,
            'fromManifestSHA256':old_manifest_sha,'toManifestSHA256':new_manifest_sha}
    result=workspace/'RESULT.json'
    journal(result,record)
    shutil.copytree(source,staged,copy_function=shutil.copy2)
    require(manifest(staged)==new_manifest,'staging 복사 불일치')
    verify_signature(staged);sync_bundle(staged)
    record['phase']='staged';journal(result,record);checkpoint('staged')
    check_idle();preflight()
    require(manifest(source)==new_manifest and manifest(destination)==old_manifest,'게시 직전 산출물 변경')
    sync_bundle(destination)
    rename_exclusive(destination,backup);sync_directory(destination.parent);sync_directory(workspace)
    require(manifest(backup)==old_manifest,'이전 bundle 보존 불일치')
    record['phase']='oldMoved';journal(result,record);checkpoint('oldMoved')
    rename_exclusive(staged,destination);sync_directory(destination.parent);sync_directory(workspace)
    record['phase']='published';journal(result,record);checkpoint('published')
    require(manifest(destination)==new_manifest and manifest(backup)==old_manifest,'게시 후 산출물 불일치')
    verify_signature(destination);preflight()
    record['phase']='verified';journal(result,record)
    return record

def unique_object(pairs):
    out={}
    for k,v in pairs:
        require(k not in out,'중복 JSON key');out[k]=v
    return out

def verify_receipt(path,destination,old_manifest_sha,new_manifest_sha,verify_signature):
    require(path.resolve()==path and path.name=='RESULT.json','교체 증거 경로 불일치')
    workspace=path.parent
    prefix='.CodexSplit-work-replacement-'
    suffix=workspace.name[len(prefix):]
    require(workspace.parent==destination.parent and workspace.name.startswith(prefix) and len(suffix)==32 and
            all(c in '0123456789abcdef' for c in suffix),'교체 증거 범위 불일치')
    for p,mode in [(workspace,0o700),(path,0o600)]:
        s=p.lstat();require(not p.is_symlink() and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==mode,'교체 증거 권한 불일치')
    info=path.lstat();require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=1_048_576,'교체 증거 파일 형식 불일치')
    r=json.loads(path.read_bytes(),object_pairs_hook=unique_object)
    require(set(r)=={'phase','backup','staging','destination','oldManifest','newManifest','stateTransitionPerformed','fromManifestSHA256','toManifestSHA256'},'교체 증거 unknown field')
    require(r['phase']=='verified' and r['stateTransitionPerformed'] is False and r['destination']==str(destination) and
            r['backup']==str(workspace/'previous.app') and r['staging']==str(workspace/'candidate.app'),'교체 검증 완료 증거 없음')
    require(r['fromManifestSHA256']==old_manifest_sha and r['toManifestSHA256']==new_manifest_sha and
            manifest_digest(r['oldManifest'])==old_manifest_sha and manifest_digest(r['newManifest'])==new_manifest_sha,'승인 교체 manifest 불일치')
    require(manifest(destination)==r['newManifest'] and manifest(workspace/'previous.app')==r['oldManifest'],'교체 대상/백업 변경')
    verify_signature(destination);verify_signature(workspace/'previous.app')
    return r

def signed(path):
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == 'local.codexsplit.work' and info.get('CFBundleExecutable') == 'launcher',
            'bundle ID 불일치')


def safe(path, directory=False, private=False):
    info = path.lstat()
    require(path.resolve() == path and not path.is_symlink(), '경로 귀속 불일치')
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), '파일 형식 불일치')
    require(info.st_uid == os.getuid(), '소유자 불일치')
    if private:
        require(stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600), '비공개 권한 불일치')
    if not directory:
        require(info.st_nlink == 1, '다중 링크 차단')
    return {'device': info.st_dev, 'inode': info.st_ino}
