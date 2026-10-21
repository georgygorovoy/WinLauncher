#!/usr/bin/env python3
"""Verify and reconstruct source materials into a new directory; never compile."""
import hashlib,io,json,sys,tarfile
from pathlib import Path,PurePosixPath
root=Path(__file__).resolve().parent
if len(sys.argv)!=2:raise SystemExit('Usage: reconstruct.py NEW_DIRECTORY')
destination=Path(sys.argv[1]).absolute()
if destination.exists() or destination.is_symlink():raise SystemExit('Destination must not exist')
index=json.loads((root/'index.json').read_text())
records=[index['xodus_source'],*index['source_inputs']]
for record in records:
 path=root/record['path']
 if not path.resolve().is_relative_to(root):raise SystemExit('Unsafe source index path')
 if hashlib.sha256(path.read_bytes()).hexdigest()!=record['sha256']:raise SystemExit('Source hash mismatch: '+record['path'])
destination.mkdir(parents=True)
for record in records:
 data=(root/record['path']).read_bytes()
 if record is index['xodus_source'] or record.get('kind')=='git':
  prefix=destination if record is index['xodus_source'] else destination/'git-sources'
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
   for member in archive:
    path=PurePosixPath(member.name)
    if path.is_absolute() or '..' in path.parts or '\\' in member.name or not member.isfile():raise SystemExit('Unsafe archive member')
    target=prefix/str(path)
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('xb') as out:out.write(archive.extractfile(member).read())
    target.chmod(member.mode&0o777)
 else:
  path=Path(record['path']).relative_to('source');target=destination/path;target.parent.mkdir(parents=True,exist_ok=True)
  with target.open('xb') as out:out.write(data)
print('Verified and reconstructed',len(records),'inputs; no build performed.')
