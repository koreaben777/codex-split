import importlib.util, tempfile, unittest, os, hashlib
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/launcher_replacement.py'

class ReplaceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file())
        spec = importlib.util.spec_from_file_location('replace_gui', SOURCE)
        self.m = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.m)
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.src, self.dest = self.root/'source.app', self.root/'installed.app'
        for p, text in [(self.src,'new'),(self.dest,'old')]:
            p.mkdir(mode=0o700); (p/'launcher').write_text(text)
        self.old = self.m.manifest(self.dest); self.new = self.m.manifest(self.src)
    def run_replace(self, **kw):
        args = dict(source=self.src, destination=self.dest, old_manifest=self.old, new_manifest=self.new,
                    old_manifest_sha=self.m.manifest_digest(self.old),new_manifest_sha=self.m.manifest_digest(self.new),
                    verify_signature=lambda p: None, check_idle=lambda: None, preflight=lambda: None)
        args.update(kw); return self.m.replace(**args)
    def test_success_preserves_old_and_new(self):
        result = self.run_replace()
        self.assertEqual(self.m.manifest(self.dest),self.new)
        self.assertEqual(self.m.manifest(Path(result['backup'])),self.old)
        self.assertEqual(result['phase'],'verified')
    def test_old_change_blocks(self):
        (self.dest/'launcher').write_text('different')
        with self.assertRaises(RuntimeError): self.run_replace()
    def test_source_change_blocks(self):
        (self.src/'launcher').write_text('different')
        with self.assertRaises(RuntimeError): self.run_replace()
    def test_symlink_blocks(self):
        (self.src/'link').symlink_to(self.dest/'launcher')
        with self.assertRaises(RuntimeError): self.run_replace()
    def test_hardlink_blocks(self):
        os.link(self.src/'launcher',self.src/'link')
        with self.assertRaises(RuntimeError): self.run_replace()
    def test_running_launcher_blocks(self):
        def busy(): raise RuntimeError('런처 실행 중')
        with self.assertRaises(RuntimeError): self.run_replace(check_idle=busy)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def test_invalid_signature_blocks(self):
        def invalid(p): raise RuntimeError('서명 변경')
        with self.assertRaises(RuntimeError): self.run_replace(verify_signature=invalid)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def test_preflight_blocks(self):
        def denied(): raise RuntimeError('관측 없음')
        with self.assertRaises(RuntimeError): self.run_replace(preflight=denied)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def test_middle_failure_preserves_backup_and_journal(self):
        def interrupt(phase):
            if phase=='oldMoved': raise RuntimeError('중단')
        with self.assertRaises(RuntimeError): self.run_replace(checkpoint=interrupt)
        records=list(self.root.glob('.CodexSplit-work-replacement-*/RESULT.json'))
        import json
        r=json.loads(records[0].read_text())
        self.assertEqual(r['phase'],'oldMoved')
        self.assertEqual(self.m.manifest(Path(r['backup'])),self.old)
        self.assertFalse(self.dest.exists())
    def test_post_publish_failure_preserves_both(self):
        def interrupt(phase):
            if phase=='published': raise RuntimeError('중단')
        with self.assertRaises(RuntimeError): self.run_replace(checkpoint=interrupt)
        self.assertEqual(self.m.manifest(self.dest),self.new)
        backups=list(self.root.glob('.CodexSplit-work-replacement-*/previous.app'))
        self.assertEqual(self.m.manifest(backups[0]),self.old)
    def test_late_source_change_blocks_before_move(self):
        def interrupt(phase):
            if phase=='staged': (self.src/'launcher').write_text('changed')
        with self.assertRaises(RuntimeError): self.run_replace(checkpoint=interrupt)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def test_late_destination_appearance_never_overwrites(self):
        def interrupt(phase):
            if phase=='oldMoved': self.dest.mkdir(mode=0o700); (self.dest/'keep').write_text('preserve')
        with self.assertRaises(OSError): self.run_replace(checkpoint=interrupt)
        self.assertEqual((self.dest/'keep').read_text(),'preserve')
    def test_approved_manifest_change_blocks(self):
        with self.assertRaises(RuntimeError): self.run_replace(new_manifest_sha='0'*64)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def test_old_approved_manifest_change_blocks(self):
        with self.assertRaises(RuntimeError): self.run_replace(old_manifest_sha='0'*64)
        self.assertEqual(self.m.manifest(self.dest),self.old)
    def verify_receipt(self,path):
        return self.m.verify_receipt(path,self.dest,self.m.manifest_digest(self.old),self.m.manifest_digest(self.new),lambda p:None)
    def test_verified_receipt_accepts_only_exact_manifests(self):
        r=self.run_replace();path=Path(r['backup']).parent/'RESULT.json'
        proof=self.verify_receipt(path)
        self.assertEqual(proof['phase'],'verified')
        (self.dest/'extra').write_text('unreviewed')
        with self.assertRaises(RuntimeError): self.verify_receipt(path)
    def test_published_receipt_not_verified(self):
        def interrupt(phase):
            if phase=='published': raise RuntimeError('중단')
        with self.assertRaises(RuntimeError): self.run_replace(checkpoint=interrupt)
        path=list(self.root.glob('.CodexSplit-work-replacement-*/RESULT.json'))[0]
        with self.assertRaises(RuntimeError): self.verify_receipt(path)
    def test_receipt_unknown_field_rejected(self):
        import json
        r=self.run_replace();path=Path(r['backup']).parent/'RESULT.json'
        r['rawLog']='forbidden';path.write_text(json.dumps(r))
        with self.assertRaises(RuntimeError): self.verify_receipt(path)
    def test_backup_changed_receipt_rejected(self):
        r=self.run_replace();path=Path(r['backup']).parent/'RESULT.json'
        (Path(r['backup'])/'launcher').write_text('changed')
        with self.assertRaises(RuntimeError): self.verify_receipt(path)

if __name__=='__main__': unittest.main()
